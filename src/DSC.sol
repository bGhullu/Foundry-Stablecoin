//SPDX-License-Identifier: MIT

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

pragma solidity ^0.8.19;

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

contract DSCEngine {
    ///////////////////
    // Errors        //
    ///////////////////

    error DSCEngine__AmountNeedsMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__IllegalState();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__MintFailed();

    ///////////////////
    //Struct         //
    ///////////////////
    struct Account {
        uint256 amountCollateral;
        uint256 amountDscMinted;
        uint256 totalDscMinted;
    }

    struct UpdateAccount {
        address user;
        address tokenCollateralAddress;
        uint256 amountCollateral;
        uint256 amountDscMinted;
    }

    struct CollateralTokens {
        address[] tokenAddresses;
        address[] priceFeedAddresses;
    }

    ////////////////////////
    // State Variables    //
    ////////////////////////
    mapping(address user => mapping(address token => Account account))
        private accounts;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQIDATION_BONUS = 10; // this mean a 10% bonus

    // address[] private s_collateralToken;
    DecentralizedStableCoin public immutable i_dsc;
    CollateralTokens private tokens;

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
        bool allowed = false;
        for (uint256 i = 0; i < tokens.tokenAddresses.length; i++) {
            if (tokens.tokenAddresses[i] == _token) {
                allowed = true;
                break;
            }
        }
        if (!allowed) {
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
        address dscAddress // uint256 numbersOfCollateral
    ) {
        if (_tokenAddresses.length != _priceFeedAddresses.length)
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

        tokens = CollateralTokens({
            tokenAddresses: _tokenAddresses,
            priceFeedAddresses: _priceFeedAddresses
        });

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
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI (check effects interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public {
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
    function mintDsc(uint256 amountDscToMint) public {
        _updateAccount(
            UpdateAccount({
                user: msg.sender,
                tokenCollateralAddress: address(0),
                amountCollateral: 0,
                amountDscMinted: amountDscToMint
            })
        );
        // _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    //////////////////////////////////
    // Private & Internal Functions //
    //////////////////////////////////

    function _updateAccount(UpdateAccount memory params) internal {
        Account storage account = accounts[params.user][
            params.tokenCollateralAddress
        ];
        account.amountCollateral += params.amountCollateral;
        account.amountDscMinted += params.amountDscMinted;

        if (account.amountCollateral < 0 || account.amountDscMinted < 0) {
            revert DSCEngine__IllegalState();
        }

        if (params.amountDscMinted > 0) {
            Account storage totalAccount = accounts[params.user][address(0)];
            totalAccount.totalDscMinted += params.amountDscMinted;
        }
    }

    function _getAccountInformation(
        address user
    )
        internal
        view
        returns (
            address[] memory tokenAddresses,
            uint256[] memory amountCollateral,
            uint256 totalDscMinted
        )
    {
        tokenAddresses = tokens.tokenAddresses;
        amountCollateral = new uint256[](tokenAddresses.length);
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            amountCollateral[i] = accounts[user][tokenAddresses[i]]
                .amountCollateral;
        }
        totalDscMinted = accounts[user][address(0)].totalDscMinted;
    }
}
