// // SPDX-License-Identifier: MIT

// //What are our invariants?
// // - Total supply of DSC should be less thaan the total value of all collateral
// // - Getter view functions should never revert

// pragma solidity ^0.8.18;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DecentralizedStableCoin dsc;
//     DSCEngine engine;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, engine, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(engine));
//     }

//     function invariant_ProtocolTotalSupplyLessThanCollateralValue() external view returns (bool) {
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsc));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsc));
//         uint256 totalCollateralValue =
//             engine.getUsdValue(weth, totalWethDeposited) + engine.getUsdValue(wbtc, totalWbtcDeposited);
//         assert(totalSupply <= totalCollateralValue);
//     }
// }
