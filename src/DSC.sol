// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSC Engine
 * @notice This contract is the core of the DSC System. It handles all the logic for minting
 * and redeeming DSC, as well as depositing and withdrawing collateral.
 * @dev This contract is inspired by the MakerDAO DSS (DAI) system but simplified and without governance.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors        //
    ///////////////////

    error DSCEngine__AmountNeedsMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__IllegalState();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__MintFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////
    // Structs       //
    ///////////////////
    struct Account {
        uint256 amountCollateral;
        uint256 amountDscMinted;
    }

    ////////////////////////
    // State Variables    //
    ////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQIDATION_BONUS = 10; // this mean a 10% bonus
    mapping(address => mapping(address => Account)) private accounts;
    mapping(address => address) public s_priceFeeds; // Mapping from token address to price feed address
    address[] private s_collateralTokens; // List of allowed collateral tokens
    DecentralizedStableCoin public immutable i_dsc;

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
        address[] memory _tokenAddresses,
        address[] memory _priceFeedAddresses,
        address dscAddress
    ) {
        if (_tokenAddresses.length != _priceFeedAddresses.length)
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    /////////////////////////

    /**
     * @notice Deposits collateral and mints DSC in one transaction
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC token to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Deposits collateral
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
    {
        accounts[msg.sender][tokenCollateralAddress]
            .amountCollateral += amountCollateral;
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) revert DSCEngine__TransferFailed();
    }

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral); // RedeemCollateral already checks Health Factor
    }

    // In order to redeem collateral:
    // 1. Health factor must be over 1 After collateral pulled
    // DRY: Don't repeat yourself

    //CEI: Check, Effects, Interactions
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Mints DSC
     * @param amountDscToMint The amount of DSC token to mint
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) {
        accounts[msg.sender][address(0)].amountDscMinted += amountDscToMint;
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    function burnDsc(uint256 amountOfDsc) public moreThanZero(amountOfDsc) {
        _burnDsc(amountOfDsc, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit.....
    }

    // If we do start nearing undercollateralization, we need someone to liquidate positions

    // $100 ETH backing $50 DSC
    // If ETH price tank.. $20 ETH back $50 DSC <- DSC isn't worth $1

    // $75 backing $50 DSC
    // Liquidator take $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     *
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be
     * below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health
     * factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200%
     * overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then
     * we couldn't be able to incentive the liquidators
     * For example, if the price of the collateral plummets before anyone could be liquidated.
     *
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        //need to check health factor of the user
        uint256 startingUserHealthFactor = _healtFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC = $ETH ?
        // = 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // And give thme a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event protocol is insolvent
        // And sweep extra amounts into a treasury

        // 0.05 ETH * 0.1 = 0.005 ETH. They will get 0.005+0.05 = 0.055 ETH in total
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQIDATION_BONUS) / LIQIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            user,
            msg.sender,
            collateral,
            totalCollateralToRedeem
        );

        // Burn DSC
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healtFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    //////////////////////////////////
    // Private & Internal Functions //
    //////////////////////////////////

    function _getAccountInformation(
        address user
    )
        public
        view
        returns (
            // uint256[] memory amountsCollateral,
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        )
    {
        // amountsCollateral = new uint256[](s_collateralTokens.length);

        // for (uint256 i = 0; i < s_collateralTokens.length; i++) {
        //     amountsCollateral[i] = accounts[user][s_collateralTokens[i]]
        //         .amountCollateral;
        // }

        totalDscMinted = accounts[user][address(0)].amountDscMinted;
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     *
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */

    function _healtFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        // health factor = (collateral value * liquidation threshold)/ minted value
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQIDATION_THRESHOLD) / LIQIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     *
     * @dev Low-level internal function, do not call unless the function calling it is
     * checking for health factors being broken
     */

    function _burnDsc(
        uint256 amountOfDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        accounts[onBehalfOf][address(0)].amountDscMinted -= amountOfDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountOfDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountOfDscToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) internal {
        accounts[from][tokenCollateralAddress]
            .amountCollateral -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // 1. Check health factor (do they have enough collateral)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healtFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////
    // Public & External View Function//
    ////////////////////////////////////

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValue) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address _token = s_collateralTokens[i];
            uint256 amountDeposited = accounts[user][_token].amountCollateral;
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

// // This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// // Layout of Contract:
// // version
// // imports
// // interfaces, libraries, contracts
// // errors
// // Type declarations
// // State variables
// // Events
// // Modifiers
// // Functions

// // Layout of Functions:s
// // constructor
// // receive function (if exists)
// // fallback function (if exists)
// // external
// // public
// // internal
// // private
// // view & pure functions

// pragma solidity ^0.8.19;

// import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
// import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// /**
//  * @title DSC Engine
//  * @author B. GHULLU
//  *
//  * The system is designed to be as minimal as possible, and have the tokens maintain a
//  * 1 token == $1 peg.
//  * This stablecoin has the properties:
//  * - Exogenous Collateral
//  * - Dollar Pegged
//  * - Algoritmicially Stable
//  *
//  * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
//  *
//  * Our DSC system should always be "overcollateralized". At no point, should the value of
//  * all collateral <= the $ backed value of all the DSC.
//  *
//  * @notice This contract is the core of the DSC System. It handles all the logic for mining
//  * and redeeming DSC, as well as depositing $ withdrawing collateral.
//  * @notice This contracct is VERY loosely based on the MakerDAO DSS (DAI) system.
//  */

// contract DSCEngine {
//     ///////////////////
//     // Errors        //
//     ///////////////////

//     error DSCEngine__AmountNeedsMoreThanZero();
//     error DSCEngine__NotAllowedToken();
//     error DSCEngine__TransferFailed();
//     error DSCEngine__IllegalState();
//     error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
//     error DSCEngine__MintFailed();

//     ///////////////////
//     //Struct         //
//     ///////////////////
//     struct Account {
//         uint256 amountCollateral;
//         uint256 amountDscMinted;
//         uint256 totalDscMinted;
//     }

//     struct UpdateAccount {
//         address user;
//         address tokenCollateralAddress;
//         uint256 amountCollateral;
//         uint256 amountDscMinted;
//     }

//     struct CollateralTokens {
//         address[] tokenAddresses;
//         address[] priceFeedAddresses;
//     }

//     ////////////////////////
//     // State Variables    //
//     ////////////////////////
//     mapping(address user => mapping(address token => Account account))
//         private accounts;
//     uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
//     uint256 private constant PRECISION = 1e18;
//     uint256 private constant LIQIDATION_THRESHOLD = 50; // 200% overcollateralized
//     uint256 private constant LIQIDATION_PRECISION = 100;
//     uint256 private constant MIN_HEALTH_FACTOR = 1e18;
//     uint256 private constant LIQIDATION_BONUS = 10; // this mean a 10% bonus

//     // address[] private s_collateralToken;
//     DecentralizedStableCoin public immutable i_dsc;
//     CollateralTokens private tokens;

//     ///////////////////
//     // Modifiers     //
//     ///////////////////

//     modifier moreThanZero(uint256 amount) {
//         if (amount == 0) {
//             revert DSCEngine__AmountNeedsMoreThanZero();
//         }
//         _;
//     }
//     modifier isAllowedToken(address _token) {
//         bool allowed = false;
//         for (uint256 i = 0; i < tokens.tokenAddresses.length; i++) {
//             if (tokens.tokenAddresses[i] == _token) {
//                 allowed = true;
//                 break;
//             }
//         }
//         if (!allowed) {
//             revert DSCEngine__NotAllowedToken();
//         }
//         _;
//     }

//     ///////////////////
//     // Functions     //
//     ///////////////////
//     constructor(
//         address[] memory _tokenAddresses,
//         address[] memory _priceFeedAddresses,
//         address dscAddress // uint256 numbersOfCollateral
//     ) {
//         if (_tokenAddresses.length != _priceFeedAddresses.length)
//             revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

//         tokens = CollateralTokens({
//             tokenAddresses: _tokenAddresses,
//             priceFeedAddresses: _priceFeedAddresses
//         });

//         i_dsc = DecentralizedStableCoin(dscAddress);
//     }

//     /////////////////////////
//     // External Functions  //
//     /////////////////////////

//     /**
//      *
//      * @param tokenCollateralAddress The address of the token to deposit as collateral
//      * @param amountCollateral The amount of collateral to deposit
//      * @param amountDscToMint The amount of DSC token to mint
//      * @notice This function will deposit your collateral and mint DSC in one tx
//      */
//     function depositCollateralAndMintDsc(
//         address tokenCollateralAddress,
//         uint256 amountCollateral,
//         uint256 amountDscToMint
//     ) external {
//         depositCollateral(tokenCollateralAddress, amountCollateral);
//         mintDsc(amountDscToMint);
//     }

//     /**
//      * @notice follows CEI (check effects interactions)
//      * @param tokenCollateralAddress The address of the token to deposit as collateral
//      * @param amountCollateral The amount of collateral to deposit
//      */
//     function depositCollateral(
//         address tokenCollateralAddress,
//         uint256 amountCollateral
//     ) public {
//         _updateAccount(
//             UpdateAccount({
//                 user: msg.sender,
//                 tokenCollateralAddress: tokenCollateralAddress,
//                 amountCollateral: amountCollateral,
//                 amountDscMinted: 0
//             })
//         );
//         bool success = IERC20(tokenCollateralAddress).transferFrom(
//             msg.sender,
//             address(this),
//             amountCollateral
//         );
//         if (!success) revert DSCEngine__TransferFailed();
//     }

//     /**
//      *
//      * @notice follows CEI
//      * @param amountDscToMint The amount of DSC token to mint
//      * @notice they must have more collateral value than the minimum threshold
//      *
//      */
//     function mintDsc(uint256 amountDscToMint) public {
//         _updateAccount(
//             UpdateAccount({
//                 user: msg.sender,
//                 tokenCollateralAddress: address(0),
//                 amountCollateral: 0,
//                 amountDscMinted: amountDscToMint
//             })
//         );
//         // _revertIfHealthFactorIsBroken(msg.sender);

//         bool minted = i_dsc.mint(msg.sender, amountDscToMint);
//         if (!minted) revert DSCEngine__MintFailed();
//     }

//     //////////////////////////////////
//     // Private & Internal Functions //
//     //////////////////////////////////

//     function _updateAccount(UpdateAccount memory params) internal {
//         Account storage account = accounts[params.user][
//             params.tokenCollateralAddress
//         ];
//         account.amountCollateral += params.amountCollateral;
//         account.amountDscMinted += params.amountDscMinted;

//         if (account.amountCollateral < 0 || account.amountDscMinted < 0) {
//             revert DSCEngine__IllegalState();
//         }

//         if (params.amountDscMinted > 0) {
//             Account storage totalAccount = accounts[params.user][address(0)];
//             totalAccount.totalDscMinted += params.amountDscMinted;
//         }
//     }

//     function _getAccountInformation(
//         address user
//     )
//         internal
//         view
//         returns (
//             address[] memory tokenAddresses,
//             uint256[] memory amountCollateral,
//             uint256 totalDscMinted
//         )
//     {
//         tokenAddresses = tokens.tokenAddresses;
//         amountCollateral = new uint256[](tokenAddresses.length);
//         for (uint256 i = 0; i < tokenAddresses.length; i++) {
//             amountCollateral[i] = accounts[user][tokenAddresses[i]]
//                 .amountCollateral;
//         }
//         totalDscMinted = accounts[user][address(0)].totalDscMinted;
//     }
// }
