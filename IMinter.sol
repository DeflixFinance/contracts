// SPDX-License-Identifier: WTFPL License
pragma solidity ^0.8.0;

interface IMinter {
    function mint(address to, uint256 amount) external;
}
