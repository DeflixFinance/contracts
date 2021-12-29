// SPDX-License-Identifier: WTFPL License
pragma solidity >=0.6.0;

import "./FarmStrategy.sol";

contract Strategy_WAG is FarmStrategy {
    constructor(
        address _flixFarmAddress,
        address _wantAddress,
        address _token0Address,
        address _token1Address,
        address _rewardsAddress,        
        uint256 _pid        
    ) FarmStrategy() {
        wnativeAddress = 0xc579D1f3CF86749E05CD06f7ADe17856c2CE3126;
        flixFarmAddress = _flixFarmAddress;
        
        wantAddress = _wantAddress;
        token0Address = _token0Address;
        token1Address = _token1Address;
        earnedAddress = 0xaBf26902Fd7B624e0db40D31171eA9ddDf078351;

        farmContractAddress = 0xa7e8280b8CE4f87dFeFc3d1F2254B5CCD971E852;
        pid = _pid;        
        isAutoComp = true;

        uniRouterAddress = 0x3D1c58B6d4501E34DF37Cf0f664A58059a188F00;
        rewardsAddress = _rewardsAddress;

        transferOwnership(flixFarmAddress);
    }
}

