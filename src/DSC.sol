// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:s
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSC Engine
 * @author B. GHULLU
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a
 * 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmicially Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining
 * and redeeming DSC, as well as depositing $ withdrawing collateral.
 * @notice This contracct is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors        //
    ///////////////////
    error DSCEngine__AmountNeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__IllegalState();

    ////////////////////////
    // State Variables    //
    ////////////////////////

    struct Account {
        uint256 amountCollateral;
        uint256 amountDscMinted;
    }

    struct UpdateAccount {
        address user;
        address tokenCollateralAddress;
        uint256 amountCollateral;
        uint256 amountDscMinted;
    }

    mapping(address user => mapping(address token => Account account))
        private accounts;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQIDATION_BONUS = 10; // this mean a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amoutnDscMinted) private s_DSCMinted;
    address[] private s_collateralToken;
    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////
    //Events         //
    ///////////////////

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );
    ///////////////////
    // Modifiers     //
    ///////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__AmountNeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////
    // Functions     //
    ///////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralToken.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    /////////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC token to mint
     * @notice This function will deposit your collateral and mint DSC in one tx
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(tokenCollateralAddress, amountDscToMint);
    }

    /**
     * @notice follows CEI (check effects interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        _updateAccount(
            UpdateAccount({
                user: msg.sender,
                tokenCollateralAddress: tokenCollateralAddress,
                amountCollateral: amountCollateral,
                amountDscMinted: 0
            })
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     *
     * @notice follows CEI
     * @param amountDscToMint The amount of DSC token to mint
     * @notice they must have more collateral value than the minimum threshold
     *
     */

    function mintDsc(
        address tokenCollateralAddress,
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        _updateAccount(
            UpdateAccount({
                user: msg.sender,
                tokenCollateralAddress: tokenCollateralAddress,
                amountCollateral: 0,
                amountDscMinted: amountDscToMint
            })
        );
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    //////////////////////////////////
    // Private & Internal Functions //
    //////////////////////////////////

    function _getAccountInformation(
        address user
    )
        internal
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValuedInUsd
        ) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValuedInUsd *
            LIQIDATION_THRESHOLD) / LIQIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _updateAccount(UpdateAccount memory params) internal {
        Account storage account = accounts[params.user][
            params.tokenCollateralAddress
        ];
        uint256 updatedCollateral = account.amountCollateral +
            params.amountCollateral;
        uint256 updatedDscMinted = account.amountDscMinted +
            params.amountDscMinted;
        if (updatedCollateral < 0 || updatedDscMinted < 0) {
            revert DSCEngine__IllegalState();
        }
        account.amountCollateral = updatedCollateral;
        account.amountDscMinted = updatedDscMinted;
    }

    ////////////////////////////////////
    // Public & External View Function//
    ////////////////////////////////////

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValue) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralToken.length; i++) {
            address _token = s_collateralToken[i];
            uint256 amountDeposited = s_collateralDeposited[user][_token];
            totalCollateralValue += getUsdValue(_token, amountDeposited);
        }
        return totalCollateralValue;
    }

    function getUsdValue(
        address _token,
        uint256 _amount
    ) public view returns (uint256 valueInUsd) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            valueInUsd =
                (_amount * (ADDITIONAL_FEED_PRECISION * uint256(price))) /
                PRECISION;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountinWei
    ) public view returns (uint256) {
        // price of token( e.g ETH)
        // $/ETH ETH??
        // $2000 / ETH $1000/$2000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        return
            (usdAmountinWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
}
