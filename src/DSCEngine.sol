// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DefiStableCoin} from "./DefiStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol"; // 新版迁移到shared/interfaces中了
import {console} from "forge-std/console.sol";
/**
 * @title DSCEngine
 * @author XiangGuanghua
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 * @notice This is the contract meant to be owned by DSCEngine. It is a ERC20 token that can be minted and burned by the DSCEngine smart contract.
 */

contract DSCEngine is ReentrancyGuard {
    //-------------------------errors----------------------//
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor); // 检查健康状态
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImporved();

    //-------------------state variables-------------------//
    //mappings
    // 存储“货币合约地址 => 价格合约地址”，便于知道token 对应的 token PriceFeed。 如: address(ETH contract) => address(ETH/USD contract)
    mapping(address token => address priceFeed) private s_priceFeeds;
    // 存储“用户地址 => “货币合约地址 => 抵押数量””，便于知道用户抵押了那种货币多少数量，如：address(user) =>"address(ETH contract) => 100 eth"
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    // 存储“用户地址 => 铸造DSC数量”，如：address(user) => 100 DSC
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    // variables
    DefiStableCoin private immutable i_Dsc;
    address[] private s_collateralTokens;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% covercollateralized value
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1000 DSC
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    //-------------------------events----------------------//
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    //------------------------modifiers--------------------//
    // 数量验证
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    // 地址验证
    modifier isAllowerToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //--------------------------------functions----------------------------------//
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        // for example ETH/USD ，BTC/USD ，BNB/USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]); // 存储抵押物合约地址
        }
        i_Dsc = DefiStableCoin(dscAddress);
    }

    //--------------------------------external functions----------------------------------//
    /**
     * 将抵押物铸造成DSC
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
     *
     * @notice 用户质押
     * @notice follow CEI pattern
     * @param tokenCollateralAddress 抵押物合约地址
     * @param amountCollateral 抵押物数量
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        isAllowerToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant //nonReentrant 重入攻击验证，会消耗一点Gas但是比较安全
    {
        // 增加调用者的抵押物
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        /**
         * solidity 接口调用原理：
         * 1.接口的本质:接口（Interface） 是一组函数签名的集合，仅定义函数名、参数和返回值，不包含具体实现。
         * 2.动态调用: 当通过接口调用 transferFrom 时，Solidity 会执行以下步骤：
         *   1）ABI编码：将函数签名（transferFrom(address,address,uint256)）和参数（msg.sender, address(this), amountCollateral）编码为二进制数据。
         *   2）发送调用：向 TOKEN_ADDRESS 发送一笔 外部调用（External Call），附带编码后的数据。
         *   3）目标合约执行：TOKEN_ADDRESS 合约接收到调用后：根据函数选择器（Function Selector）定位到 transferFrom 方法。执行其内部逻辑（如检查授权、修改余额等）。
         *   4）返回结果：操作结果（success）返回给调用者。
         * 3.关键点：
         *   1）接口无实现，但目标合约有实现：接口只是调用规范，实际逻辑由目标合约（如 USDC 合约）实现。
         *   2）动态绑定：在运行时，通过地址 TOKEN_ADDRESS 找到具体合约并执行其代码。
         */
        /**
         * @notice 转移抵押物
         * @notice IERC20(tokenCollateralAddress) 是类型转换，将指定的 tokenCollateralAddress 合约地址 转换为 IERC20 类型，从而能够调用 IERC20 接口中的方法。
         * @notice 接口调用是一种通过合约地址与其他已部署合约进行交互的方式。
         * 当调用 IERC20(tokenAddress).transferFrom(...) 时，实际上你是在与一个已经部署的 ERC20 合约 进行交互，而这个 ERC20 合约 已经实现了 这些方法。
         * ERC20 合约本身会继承 IERC20 接口，并且在它的实现中提供这些方法的具体功能。
         * @notice 目标合约（tokenCollateralAddress）必须也遵循ERC20接口标准
         */
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * 使用DSC赎回抵押物
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * 销毁抵押物
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactoryIsBroken(msg.sender);
    }

    /**
     * 铸造DSC
     * @param amountDscToMint 铸造DSC的数量
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        //存储用户铸造币的数量
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactoryIsBroken(msg.sender);
        bool minted = i_Dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * 销毁DSC
     */
    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactoryIsBroken(msg.sender);
    }

    /**
     * 清算方法
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImporved();
        }
        _revertIfHealthFactoryIsBroken(msg.sender);
    }

    //---------------------private & internal functions----------------------//

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_Dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_Dsc.burn(amountDscToBurn);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; // (150 / 100)
    }

    /**
     * 获取用户的抵押物和铸造的DSC数量
     * @param user 用户地址
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
        return (totalDscMinted, collateralValueInUsd);
    }
    /**
     * 返回用户还差多少就会被清算
     * @param user 用户地址
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; // (150 / 100)
    }

    function _revertIfHealthFactoryIsBroken(address user) internal view {
        // 检查健康状态
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //-------------------public & external & get  methods-------------------//
    /**
     * 获取投资的健康状态
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * 获取用户抵押物的USD价值
     * @param user 用户地址
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount); // totalCollateralValueInUsd
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_Dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
