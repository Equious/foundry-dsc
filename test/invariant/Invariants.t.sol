// SPDX-License-Identifier: MIT

//What are our invariants?
// - Total supply of DSC should be less thaan the total value of all collateral
// - Getter view functions should never revert

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_ProtocolTotalSupplyLessThanCollateralValue() external view returns (bool) {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));
        uint256 totalWethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 totalWbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);
        uint256 totalCollateralValue = totalWethValue + totalWbtcValue;

        console.log("weth value: ", totalWethValue);
        console.log("wbtc value: ", totalWbtcValue);
        console.log("Total Supply: ", totalSupply);
        console.log("Times Mint Called: ", handler.timesMintCalled());

        assert(totalSupply <= totalCollateralValue);
    }

    function invariant_gettersShouldNotRevert() public view {
        engine.getCollateralTokens();
        engine.getUsdValue(weth, 1);
        engine.getTokenAmountFromUsd(weth, 1);
        engine.getAccountInformation(address(this));
    }
}
