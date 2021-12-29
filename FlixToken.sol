// SPDX-License-Identifier: WTFPL License
pragma solidity >=0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FlixToken is Context, ERC20, Ownable {
    using SafeMath for uint256;
               
    uint256 private constant _maxSupply = (10*7) * 1 ether; //10 millions

    constructor () ERC20("DEFLIX","FLIX") {}

    /**
     * @dev Creates `_amount` token to `_to`. Must only be called by the owner
     */
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }
    
    function maxSupply() external pure returns (uint256) {
        return _maxSupply;
    }

    function maxSupplyReached() external view returns (bool) {
        return totalSupply() >= _maxSupply;
    }
    
    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply, making sure the maxSupply is not exceeded
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements
     *
     * - `to` cannot be the zero address.
     * - maxSupply cannot be exceeded
     */
    function _mint(address account, uint256 amount) internal override {
        require(account != address(0), "ERC20: mint to the zero address");
                
        if (totalSupply() >= _maxSupply) return;

        uint256 maxMintableAmt = _maxSupply.sub(totalSupply());
        if (amount > maxMintableAmt) {
            amount = maxMintableAmt;
        }

        super._mint(account, amount);
    }    
}
