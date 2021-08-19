import rawHRE from 'hardhat';
import { ethers, Signer } from 'ethers';
import { MockContract } from 'ethereum-waffle';
import { waitForTx } from '../helpers/misc-utils';
import { AavePools, eContractid, tEthereumAddress, TokenContractId } from '../helpers/types';
import {
  deployAaveOracle,
  deployAaveProtocolDataProvider,
  deployATokensAndRatesHelper,
  deployMintableERC20,
  deployMockFlashLoanReceiver,
  deployMockUniswapRouter,
  deployPool,
  deployPoolAddressesProvider,
  deployPoolAddressesProviderRegistry,
  deployPoolConfigurator,
  deployPriceOracle,
  deployRateOracle,
  deployStableAndVariableTokensHelper,
  deployWalletBalancerProvider,
  deployWETHGateway,
  deployWETHMocked,
} from '../helpers/contracts-deployments';
import {
  deployAllMockAggregators,
  setInitialAssetPricesInOracle,
  setInitialMarketRatesInRatesOracleByHelper,
} from '../helpers/oracles-helpers';
import { insertContractAddressInDb, registerContractInJsonDb } from '../helpers/contracts-helpers';

import { getEthersSigners, getEthersSignersAddresses } from '../helpers/wallet-helpers';
import { ZERO_ADDRESS } from '../helpers/constants';
import {
  getPairsTokenAggregator,
  getPool,
  getPoolConfiguratorProxy,
} from '../helpers/contracts-getters';
import {
  ConfigNames,
  getReservesConfigByPool,
  getTreasuryAddress,
  loadPoolConfig,
} from '../helpers/configuration';
import AaveConfig from '../markets/aave';
import {
  authorizeWETHGateway,
  configureReservesByHelper,
  initReservesByHelper,
} from '../helpers/init-helpers';
import { initializeMakeSuite } from './helpers/make-suite';

import { MintableERC20, WETH9Mocked } from '@aave/core-v3/types';

const deployAllMockTokens = async (deployer: Signer) => {
  const tokens: { [symbol: string]: MockContract | MintableERC20 | WETH9Mocked } = {};

  const protoConfigData = getReservesConfigByPool(AavePools.proto);

  for (const tokenSymbol of Object.keys(TokenContractId)) {
    if (tokenSymbol === 'WETH') {
      tokens[tokenSymbol] = await deployWETHMocked();
      await registerContractInJsonDb(tokenSymbol.toUpperCase(), tokens[tokenSymbol]);
      continue;
    }

    let decimals = 18;
    let configData = (<any>protoConfigData)[tokenSymbol];
    if (!configData) {
      decimals = 18;
    }

    tokens[tokenSymbol] = await deployMintableERC20([
      tokenSymbol,
      tokenSymbol,
      configData ? configData.reserveDecimals : 18,
    ]);
    await registerContractInJsonDb(tokenSymbol.toUpperCase(), tokens[tokenSymbol]);
  }

  return tokens;
};

const buildTestEnv = async (deployer: Signer, secondaryWallet: Signer) => {
  console.time('setup');

  const MOCK_USD_PRICE_IN_WEI = AaveConfig.ProtocolGlobalParams.MockUsdPriceInWei;
  const ALL_ASSETS_INITIAL_PRICES = AaveConfig.Mocks.AllAssetsInitialPrices;
  const USD_ADDRESS = AaveConfig.ProtocolGlobalParams.UsdAddress;
  const MOCK_CHAINLINK_AGGREGATORS_PRICES = AaveConfig.Mocks.AllAssetsInitialPrices;
  const RATE_ORACLE_RATES_COMMON = AaveConfig.RateOracleRatesCommon;

  const aaveAdmin = await deployer.getAddress();

  const mockTokens = await deployAllMockTokens(deployer);
  console.log('Deployed mocks');
  const addressesProvider = await deployPoolAddressesProvider(AaveConfig.MarketId);
  await waitForTx(await addressesProvider.setPoolAdmin(aaveAdmin));

  //setting users[1] as emergency admin, which is in position 2 in the DRE addresses list
  const addressList = await getEthersSignersAddresses();

  await waitForTx(await addressesProvider.setEmergencyAdmin(addressList[2]));

  const addressesProviderRegistry = await deployPoolAddressesProviderRegistry();
  await waitForTx(
    await addressesProviderRegistry.registerAddressesProvider(addressesProvider.address, 1)
  );

  const poolImpl = await deployPool();

  await waitForTx(await addressesProvider.setPoolImpl(poolImpl.address));

  const poolAddress = await addressesProvider.getPool();
  const poolProxy = await getPool(poolAddress);

  await insertContractAddressInDb(eContractid.Pool, poolProxy.address);

  const poolConfiguratorImpl = await deployPoolConfigurator();
  await waitForTx(await addressesProvider.setPoolConfiguratorImpl(poolConfiguratorImpl.address));
  const poolConfiguratorProxy = await getPoolConfiguratorProxy(
    await addressesProvider.getPoolConfigurator()
  );
  await waitForTx(await poolConfiguratorProxy.registerRiskAdmin(addressList[3]));
  await insertContractAddressInDb(eContractid.PoolConfigurator, poolConfiguratorProxy.address);

  // Deploy deployment helpers
  await deployStableAndVariableTokensHelper([poolProxy.address, addressesProvider.address]);
  await deployATokensAndRatesHelper([
    poolProxy.address,
    addressesProvider.address,
    poolConfiguratorProxy.address,
  ]);

  const fallbackOracle = await deployPriceOracle();
  await waitForTx(await fallbackOracle.setEthUsdPrice(MOCK_USD_PRICE_IN_WEI));
  await setInitialAssetPricesInOracle(
    ALL_ASSETS_INITIAL_PRICES,
    {
      WETH: mockTokens.WETH.address,
      DAI: mockTokens.DAI.address,
      TUSD: mockTokens.TUSD.address,
      USDC: mockTokens.USDC.address,
      USDT: mockTokens.USDT.address,
      SUSD: mockTokens.SUSD.address,
      AAVE: mockTokens.AAVE.address,
      BAT: mockTokens.BAT.address,
      MKR: mockTokens.MKR.address,
      LINK: mockTokens.LINK.address,
      KNC: mockTokens.KNC.address,
      WBTC: mockTokens.WBTC.address,
      MANA: mockTokens.MANA.address,
      ZRX: mockTokens.ZRX.address,
      SNX: mockTokens.SNX.address,
      BUSD: mockTokens.BUSD.address,
      YFI: mockTokens.BUSD.address,
      REN: mockTokens.REN.address,
      UNI: mockTokens.UNI.address,
      ENJ: mockTokens.ENJ.address,
      // DAI: mockTokens.LpDAI.address,
      // USDC: mockTokens.LpUSDC.address,
      // USDT: mockTokens.LpUSDT.address,
      // WBTC: mockTokens.LpWBTC.address,
      // WETH: mockTokens.LpWETH.address,
      UniDAIWETH: mockTokens.UniDAIWETH.address,
      UniWBTCWETH: mockTokens.UniWBTCWETH.address,
      UniAAVEWETH: mockTokens.UniAAVEWETH.address,
      UniBATWETH: mockTokens.UniBATWETH.address,
      UniDAIUSDC: mockTokens.UniDAIUSDC.address,
      UniCRVWETH: mockTokens.UniCRVWETH.address,
      UniLINKWETH: mockTokens.UniLINKWETH.address,
      UniMKRWETH: mockTokens.UniMKRWETH.address,
      UniRENWETH: mockTokens.UniRENWETH.address,
      UniSNXWETH: mockTokens.UniSNXWETH.address,
      UniUNIWETH: mockTokens.UniUNIWETH.address,
      UniUSDCWETH: mockTokens.UniUSDCWETH.address,
      UniWBTCUSDC: mockTokens.UniWBTCUSDC.address,
      UniYFIWETH: mockTokens.UniYFIWETH.address,
      BptWBTCWETH: mockTokens.BptWBTCWETH.address,
      BptBALWETH: mockTokens.BptBALWETH.address,
      WMATIC: mockTokens.WMATIC.address,
      USD: USD_ADDRESS,
      STAKE: mockTokens.STAKE.address,
      xSUSHI: mockTokens.xSUSHI.address,
    },
    fallbackOracle
  );

  const mockAggregators = await deployAllMockAggregators(MOCK_CHAINLINK_AGGREGATORS_PRICES);
  console.log('Mock aggs deployed');
  const allTokenAddresses = Object.entries(mockTokens).reduce(
    (accum: { [tokenSymbol: string]: tEthereumAddress }, [tokenSymbol, tokenContract]) => ({
      ...accum,
      [tokenSymbol]: tokenContract.address,
    }),
    {}
  );
  const allAggregatorsAddresses = Object.entries(mockAggregators).reduce(
    (accum: { [tokenSymbol: string]: tEthereumAddress }, [tokenSymbol, aggregator]) => ({
      ...accum,
      [tokenSymbol]: aggregator.address,
    }),
    {}
  );

  const [tokens, aggregators] = getPairsTokenAggregator(allTokenAddresses, allAggregatorsAddresses);

  await deployAaveOracle([
    tokens,
    aggregators,
    fallbackOracle.address,
    mockTokens.WETH.address,
    ethers.constants.WeiPerEther.toString(),
  ]);
  await waitForTx(await addressesProvider.setPriceOracle(fallbackOracle.address));

  const rateOracle = await deployRateOracle();
  await waitForTx(await addressesProvider.setRateOracle(rateOracle.address));

  const { USD, ...tokensAddressesWithoutUsd } = allTokenAddresses;
  const allReservesAddresses = {
    ...tokensAddressesWithoutUsd,
  };
  await setInitialMarketRatesInRatesOracleByHelper(
    RATE_ORACLE_RATES_COMMON,
    allReservesAddresses,
    rateOracle,
    aaveAdmin
  );

  const reservesParams = getReservesConfigByPool(AavePools.proto);

  const testHelpers = await deployAaveProtocolDataProvider(addressesProvider.address);

  await insertContractAddressInDb(eContractid.AaveProtocolDataProvider, testHelpers.address);
  const admin = await deployer.getAddress();

  console.log('Initialize configuration');

  const config = loadPoolConfig(ConfigNames.Aave);

  const {
    ATokenNamePrefix,
    StableDebtTokenNamePrefix,
    VariableDebtTokenNamePrefix,
    SymbolPrefix,
  } = config;
  const treasuryAddress = await getTreasuryAddress(config);

  await initReservesByHelper(
    reservesParams,
    allReservesAddresses,
    ATokenNamePrefix,
    StableDebtTokenNamePrefix,
    VariableDebtTokenNamePrefix,
    SymbolPrefix,
    admin,
    treasuryAddress,
    ZERO_ADDRESS,
    false
  );

  await configureReservesByHelper(reservesParams, allReservesAddresses, testHelpers, admin);
  poolConfiguratorProxy.dropReserve(mockTokens.KNC.address);

  await deployMockFlashLoanReceiver(addressesProvider.address);

  const mockUniswapRouter = await deployMockUniswapRouter();

  const adapterParams: [string, string, string] = [
    addressesProvider.address,
    mockUniswapRouter.address,
    mockTokens.WETH.address,
  ];

  //   await deployUniswapLiquiditySwapAdapter(adapterParams);
  //   await deployUniswapRepayAdapter(adapterParams);
  //   await deployFlashLiquidationAdapter(adapterParams);

  await deployWalletBalancerProvider();

  const gateWay = await deployWETHGateway([mockTokens.WETH.address]);
  await authorizeWETHGateway(gateWay.address, poolAddress);

  console.timeEnd('setup');
};

before(async () => {
  await rawHRE.run('set-DRE');
  const [deployer, secondaryWallet] = await getEthersSigners();
  const FORK = process.env.FORK;

  if (FORK) {
    await rawHRE.run('aave:mainnet', { skipRegistry: true });
  } else {
    console.log('-> Deploying test environment...');
    await buildTestEnv(deployer, secondaryWallet);
  }

  await initializeMakeSuite();
  console.log('\n***************');
  console.log('Setup and snapshot finished');
  console.log('***************\n');
});
