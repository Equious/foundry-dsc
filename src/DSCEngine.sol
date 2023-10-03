//SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral (ETH & BTC)
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * Our DSC System should always be OVERCOLLATERALIZED. This means that the value of the collateral should always be greater than the value of the DSC.
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC.
 * @notice This contract is the core of the DSC System. It handles aall the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ///// Errors /////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAndPriceFeedLengthMismatch();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TranfserFailed();
    error DSCEngine__BreaksHealthFactor(address _user, uint256 _healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__AccountHealthy(address _user, uint256 _healthFactor);
    error DSCEngine__HealthFactorNotImproved(
        address user, uint256 startingUserHealthFactor, uint256 endingUserHealthFactor
    );

    ///// Types /////

    using OracleLib for AggregatorV3Interface;

    ///// State Variables /////

    uint256 private constant ADDITIONAL_PRICEFEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountMinted) private s_dscMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable s_dsc;

    ///// Events /////
    event DepositCollateral(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///// Modifiers /////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotSupported();
        }
        _;
    }

    ///// Functions /////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAndPriceFeedLengthMismatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        s_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * @notice This function is used to deposit collateral and mint DSC.
     * @param tokenCollateralAddress The address of the collateral token to deposit.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit DepositCollateral(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TranfserFailed();
        }
    }

    /**
     * @notice This function is used to deposit collateral and mint DSC.
     * @param tokenCollateralAddress The address of the collateral token to deposit.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC to mint.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 _amount)
        public
        moreThanZero(_amount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, _amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function is used to redeem collateral and burn DSC.
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral checks Health Factor.
    }

    /**
     * @notice Follows CEI - Checks, Effects Interactions pattern.
     * @param _amount The amount of DSC to mint.
     * @notice User must have enough collateral that minting does break the user's healthFactor
     */
    function mintDsc(uint256 _amount) public moreThanZero(_amount) nonReentrant {
        s_dscMinted[msg.sender] += _amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        s_dsc.mint(msg.sender, _amount);
        bool minted = s_dsc.mint(msg.sender, _amount);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
        _burnDsc(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //unnecessary
    }

    /**
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice You can partially liquidate a user.
     * @notice You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     *
     */
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= 1e18) {
            revert DSCEngine__AccountHealthy(user, startingUserHealthFactor);
        }
        uint256 tokenAmountfromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);
        uint256 bonusCollateral = (tokenAmountfromDebtCovered * LIQUIDATION_BONUS) / 100;
        uint256 totalCollateralToRedeem = tokenAmountfromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, tokenCollateralAddress, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor <= endingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved(user, startingUserHealthFactor, endingUserHealthFactor);
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValue)
    {
        (totalDscMinted, totalCollateralValue) = _getUserAccountInformation(user);
    }

    /**
     * Returns the health of an account reflecting a user's collateralization ratio.
     * If a user's health is below 1, the user is insolvent and can be liquidated.
     */
    function _healthFactor(address _user) internal view returns (uint256) {
        //get user's total DSC minted
        //get user's totaal collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValue) = _getUserAccountInformation(_user);
        uint256 collateralAdjustedForLiquidationThreshold = (totalCollateralValue * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForLiquidationThreshold * ADDITIONAL_PRICEFEED_PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < 1) {
            revert DSCEngine__BreaksHealthFactor(_user, userHealthFactor);
        }
    }

    function _getUserAccountInformation(address _user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValue)
    {
        totalDscMinted = s_dscMinted[_user];
        totalCollateralValue = getAccountCollateralValue(_user);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TranfserFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * low-level internal function, do not call unless the function calling it is checking for health factors being broken.
     * @param _amount amount of DSC to burn
     * @param onBehalfOf address of user being liquidated
     * @param dscFrom where the DSC is coming from
     */
    function _burnDsc(uint256 _amount, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= _amount;
        bool success = s_dsc.transferFrom(dscFrom, address(this), _amount);
        if (!success) {
            revert DSCEngine__TranfserFailed();
        }
        s_dsc.burn(_amount);
    }

    function getHealthFactor(address _user) external view {}

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueUsd) {
        // loop through each collateral token to get amount deposted and map it to the priceFeed to get the value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amountDeposited = s_collateralDeposited[_user][token];
            totalCollateralValueUsd += getUsdValue(token, amountDeposited);
        }
        return totalCollateralValueUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.stalePriceCheck();
        return (uint256(price) * ADDITIONAL_PRICEFEED_PRECISION * _amount) / 1e18;
    }

    function getTokenAmountFromUsd(address tokenAddress, uint256 usdAmount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[tokenAddress]);
        (, int256 price,,,) = priceFeed.stalePriceCheck();
        return (usdAmount * 1e18) / (uint256(price) * ADDITIONAL_PRICEFEED_PRECISION);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getUserCollateralBalance(address _user, address _token) external view returns (uint256) {
        return s_collateralDeposited[_user][_token];
    }

    function getCollateralTokenPriceFeed(address _token) external view returns (address) {
        return s_priceFeeds[_token];
    }
}
