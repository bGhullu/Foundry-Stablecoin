//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine {
    error DSCEngine__TransferFailed();
    error DSCEngine__IllegalState();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__MintFailed();

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
    mapping(address user => mapping(address token => Account account))
        private accounts;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQIDATION_BONUS = 10; // this mean a 10% bonus

    mapping(address token => address priceFeed) public s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        public s_collateralDeposited;
    mapping(address user => uint256 amoutnDscMinted) public s_DSCMinted;
    address[] private s_collateralToken;
    DecentralizedStableCoin public immutable i_dsc;

    struct CollateralTokens {
        address[] tokenAddresses;
        address[] priceFeedAddresses;
    }

    CollateralTokens private tokens;

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
    ) internal view returns (uint256 totalDscMinted) {
        Account storage userInfo = accounts[user][address(0)];
        return userInfo.totalDscMinted;
    }
}
