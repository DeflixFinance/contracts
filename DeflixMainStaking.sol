// SPDX-License-Identifier: WTFPL License
pragma solidity >=0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./IMinter.sol";
import "./FlixToken.sol";
import "./IStrategy.sol";

contract DeflixMainStaking is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 shares; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of FLIXs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFlixPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFlixPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. FLIXs to distribute per block.
        uint256 lastRewardBlock; // Last block number that FLIXs distribution occurs.
        uint256 accFlixPerShare; // Accumulated FLIXs per share, times 1e12.
        uint256 totalSharesAmt; // Current total deposit amount in this pool
        address strategy; // Address of StrategyContract
        uint16 depositFeeBP; // Deposit fee in basis points
    }

    FlixToken public flix;
    IMinter public minter;

    bool public farmingEnded;

    uint256 constant BASIS_POINTS = 10000;
    // The maximum deposit fee allowed is 10%
    uint16 constant MAX_DEPOSIT_FEE = 1000;
    uint16 constant MAX_DEV_FEE = 1200;
    // Deposit Fee address
    address public treasuryAddr;
    address public devAddr;

    uint256 devFeeBP = 700;

    uint256 public flixPerBlock = 0;
    // The block number when FLIX mining starts.
    uint256 public startBlock;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // to check if a pool with a given IERC20 already exists
    mapping(IERC20 => bool) public tokenList;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event MassHarvest(uint256[] poolsId);
    event EmergencyERC20Drain(address token, address recipient, uint256 amount);
    event UpdateEmissionPerBlock(uint256 previousValue, uint256 newValue);

    constructor(address _devAddr, address _treasuryAddr) {
        treasuryAddr = _treasuryAddr;
        devAddr = _devAddr;
    }

    modifier poolExists(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function setStartBlock(uint256 _newStartBlock) external onlyOwner {
        require(
            startBlock == 0 || block.number < startBlock,
            "already started"
        );
        require(_newStartBlock > block.number, "invalid start block");
        startBlock = _newStartBlock;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            poolInfo[pid].lastRewardBlock = startBlock;
        }
    }

    /**
     * @notice Sets the emission rate
     * @dev Only callable by the current contract owner
     */
    function setEmissionPerBlock(uint256 _newFlixPerBlock) external onlyOwner {
        massUpdatePools();
        emit UpdateEmissionPerBlock(flixPerBlock, _newFlixPerBlock);
        flixPerBlock = _newFlixPerBlock;
    }

    function setFees(uint256 _devFeesBP) external onlyOwner {
        require(_devFeesBP <= MAX_DEV_FEE, "too high");
        devFeeBP = _devFeesBP;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        address _strategy,
        bool _withUpdate
    ) external onlyOwner {
        require(
            _depositFeeBP <= MAX_DEPOSIT_FEE,
            "add: invalid deposit fee basis points"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accFlixPerShare: 0,
                totalSharesAmt: 0,
                strategy: _strategy,
                depositFeeBP: _depositFeeBP
            })
        );

        tokenList[_lpToken] = true;
    }

    // Update the given pool's FLIX allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) external onlyOwner poolExists(_pid) {
        require(
            _depositFeeBP <= MAX_DEPOSIT_FEE,
            "set: invalid deposit fee basis points"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        pool.allocPoint = _allocPoint;
        pool.depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (flix.maxSupplyReached()) {
            return 0;
        }
        return _to.sub(_from);
    }

    // View function to see pending FLIXs on frontend.
    function pendingFLIX(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFlixPerShare = pool.accFlixPerShare;
        uint256 sharesTotal = pool.totalSharesAmt;
        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 flixReward = multiplier
                .mul(flixPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accFlixPerShare = accFlixPerShare.add(
                flixReward.mul(1e12).div(sharesTotal)
            );
        }
        return user.shares.mul(accFlixPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        uint256 reward = internalUpdatePool(_pid);

        mint(reward);
    }

    // Deposit LP tokens for FLIX allocation.
    function deposit(uint256 _pid, uint256 _wantAmt)
        external
        nonReentrant
        poolExists(_pid)
    {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.shares > 0) {
            uint256 pending = user
                .shares
                .mul(pool.accFlixPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            if (pending > 0) {
                safeFLIXTransfer(msg.sender, pending);
            }
        }
        if (_wantAmt > 0) {
            uint256 initialBalance = IERC20(pool.lpToken).balanceOf(
                address(this)
            );
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _wantAmt
            );
            uint256 actualWantAmt = IERC20(pool.lpToken)
                .balanceOf(address(this))
                .sub(initialBalance);
            uint256 sharesAdded = actualWantAmt;
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = actualWantAmt.mul(pool.depositFeeBP).div(
                    BASIS_POINTS
                );
                pool.lpToken.safeTransfer(treasuryAddr, depositFee);
                sharesAdded = actualWantAmt.sub(depositFee);
            }
            if (pool.strategy != address(0)) {
                pool.lpToken.safeIncreaseAllowance(pool.strategy, sharesAdded);
                sharesAdded = IStrategy(pool.strategy).deposit(
                    msg.sender,
                    sharesAdded
                );
            }
            user.shares = user.shares.add(sharesAdded);
            pool.totalSharesAmt = pool.totalSharesAmt.add(sharesAdded);
        }
        user.rewardDebt = user.shares.mul(pool.accFlixPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens
    function withdraw(uint256 _pid, uint256 _wantAmt)
        external
        nonReentrant
        poolExists(_pid)
    {
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(pool.strategy).wantLockedTotal();
        uint256 sharesTotal = IStrategy(pool.strategy).sharesTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        uint256 pending = user.shares.mul(pool.accFlixPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (pending > 0) {
            safeFLIXTransfer(msg.sender, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }

        if (_wantAmt > 0) {
            uint256 sharesRemoved = _wantAmt;
            if (pool.strategy != address(0)) {
                sharesRemoved = IStrategy(pool.strategy).withdraw(
                    msg.sender,
                    _wantAmt
                );

                user.shares = sharesRemoved > user.shares
                    ? 0
                    : user.shares.sub(sharesRemoved);
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint256 wantBal = IERC20(pool.lpToken).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            pool.totalSharesAmt = pool.totalSharesAmt.sub(sharesRemoved);
            pool.lpToken.safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.shares.mul(pool.accFlixPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.shares;

        if (pool.strategy != address(0)) {
            uint256 wantLockedTotal = IStrategy(pool.strategy)
                .wantLockedTotal();
            uint256 sharesTotal = IStrategy(pool.strategy).sharesTotal();
            amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
            IStrategy(pool.strategy).withdraw(msg.sender, amount);
        }

        pool.totalSharesAmt = pool.totalSharesAmt.sub(user.shares);
        user.shares = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe FLIX transfer function, just in case if rounding error causes pool not to have enough FLIXs.
    function safeFLIXTransfer(address _to, uint256 _amount) internal {
        uint256 flixBal = flix.balanceOf(address(this));
        if (_amount > flixBal) {
            flix.transfer(_to, flixBal);
        } else {
            flix.transfer(_to, _amount);
        }
    }

    function setFlix(address _flixAddr, address _minter) external onlyOwner {
        flix = FlixToken(_flixAddr);
        minter = IMinter(_minter);
    }

    // Update fee address by the previous address
    function setTreasuryAddr(address _treasuryAddr) external {
        require(msg.sender == treasuryAddr, "setTreasuryAddr: FORBIDDEN");
        treasuryAddr = _treasuryAddr;
    }

    /**
     * @notice Sets dev address
     * @dev Only callable by current dev address
     */
    function setDevAddress(address _devAddr) external {
        require(msg.sender == devAddr, "setDevAddr: FORBIDDEN");
        require(_devAddr != address(0), "Cannot be zero address");
        devAddr = _devAddr;
    }

    /**
     ** @dev Harvest all pools where user has pending balance at the same time
     ** _ids[] list of pools id to harvest, [] to harvest all
     **/
    function massHarvest(uint256[] calldata _ids) external nonReentrant {
        bool zeroLenght = _ids.length == 0;
        uint256 idxlength = _ids.length;

        //if empty check all
        if (zeroLenght) {
            idxlength = poolInfo.length;
        }

        uint256 totalPending = 0;
        uint256 accumulatedFLIXReward = 0;

        for (uint256 i = 0; i < idxlength; i++) {
            uint256 pid = zeroLenght ? i : _ids[i];
            if (pid >= poolInfo.length) continue;

            accumulatedFLIXReward = accumulatedFLIXReward.add(
                internalUpdatePool(pid)
            );

            PoolInfo storage pool = poolInfo[pid];
            UserInfo storage user = userInfo[pid][msg.sender];
            uint256 pending = user
                .shares
                .mul(pool.accFlixPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            totalPending = totalPending.add(pending);
            user.rewardDebt = user.shares.mul(pool.accFlixPerShare).div(1e12);
        }

        mint(accumulatedFLIXReward);

        if (totalPending > 0) {
            safeFLIXTransfer(msg.sender, totalPending);
        }
        emit MassHarvest(_ids);
    }

    // Owner can drain tokens that are sent here by mistake, excluding FLIX and staked LP tokens
    function drainStuckToken(address _token) external onlyOwner {
        require(_token != address(flix), "FLIX cannot be drained");
        IERC20 token = IERC20(_token);
        require(tokenList[token] == false, "Pool tokens cannot be drained");
        uint256 amount = token.balanceOf(address(this));
        token.transfer(msg.sender, amount);
        emit EmergencyERC20Drain(address(token), msg.sender, amount);
    }

    /**
     * @notice Proxy call to minter
     * @dev If maxSupply is reached, farming ends
     */
    function mint(uint256 amount) internal {
        if (farmingEnded) return;
        if (amount == 0) return;
        minter.mint(address(this), amount);
        minter.mint(devAddr, amount.mul(devFeeBP).div(BASIS_POINTS));

        if (flix.maxSupplyReached()) {
            farmingEnded = true;
        }
    }

    function internalUpdatePool(uint256 _pid) internal returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return 0;
        }
        uint256 lpTotal = pool.totalSharesAmt;
        if (lpTotal == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return 0;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return 0;
        }
        uint256 flixReward = multiplier
            .mul(flixPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        pool.accFlixPerShare = pool.accFlixPerShare.add(
            flixReward.mul(1e12).div(lpTotal)
        );
        pool.lastRewardBlock = block.number;
        return flixReward;
    }
}
