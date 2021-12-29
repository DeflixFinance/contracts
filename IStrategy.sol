// SPDX-License-Identifier: WTFPL License
pragma solidity >=0.6.0;


interface IStrategy {
    // Total want tokens managed by strategy
    function wantLockedTotal() external view returns (uint256);

    // Sum of all shares of users to wantLockedTotal
    function sharesTotal() external view returns (uint256);

    // Main want token compounding function
    function earn() external;

    // Transfer want tokens from staking farm to strategy
    function deposit(address _userAddress, uint256 _wantAmt)
        external
        returns (uint256);

    // Transfer want tokens from strategy to staking farm
    function withdraw(address _userAddress, uint256 _wantAmt)
        external
        returns (uint256);
}