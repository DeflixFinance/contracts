// SPDX-License-Identifier: WTFPL License
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./IMinter.sol";
import "./FlixToken.sol";

contract FlixMinter is Ownable, IMinter {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event EmergencyDrain(address token, address recipient, uint256 amount);

    FlixToken public immutable _flix;
    
    mapping(address => bool) public _minters;

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "not a minter");
        _;
    }
    
    constructor(address flixAddr) {
        _flix = FlixToken(flixAddr);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function updateFlixMinter(address newMinter) external onlyOwner {
        Ownable(_flix).transferOwnership(newMinter);
    }

    function setMinter(address minter, bool canMint) external onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }
    
    function mint(address to, uint256 amount) external override onlyMinter {
        require(to != address(this), "cannot mint to self");
        if (amount == 0) return;

        _flix.mint(to, amount);
    }

    function drainStuckToken(address token) external onlyOwner {
        IERC20 bep20Token = IERC20(token);
        uint256 amount = bep20Token.balanceOf(address(this));
        bep20Token.transfer(msg.sender, amount);
        emit EmergencyDrain(token, msg.sender, amount);
    }

    function isMinter(address account) public view returns (bool) {
        if (_flix.owner() != address(this)) {
            return false;
        }
        return _minters[account];
    }
}
