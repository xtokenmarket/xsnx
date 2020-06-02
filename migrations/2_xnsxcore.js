const { BN } = require('@openzeppelin/test-helpers')
const migrationInputs = require('../util/migrationInputs')
const xSNXCore = artifacts.require('ExtXC')
const TradeAccounting = artifacts.require('TradeAccounting')
// mock version
const ExtTradeAccounting = artifacts.require('ExtTA')

// local env
const MockFeePool = artifacts.require('MockFeePool')
const MockERC20 = artifacts.require('MockERC20')
const MockWETH = artifacts.require('MockWETH')
const MockSUSD = artifacts.require('MockSUSD')
const MockUSDC = artifacts.require('MockUSDC')
const MockLINK = artifacts.require('MockLINK')
const MockSetToken = artifacts.require('MockSetToken')
const MockCollateralSet = artifacts.require('MockCollateralSet')
const MockExchangeRates = artifacts.require('MockExchangeRates')
const MockRewardEscrow = artifacts.require('MockRewardEscrow')
const MockAddressResolver = artifacts.require('MockAddressResolver')
const MockKyberProxy = artifacts.require('MockKyberProxy')
const MockSynthetix = artifacts.require('MockSynthetix')
const MockRebalancingModule = artifacts.require('MockRebalancingModule')
const MockSynthetixState = artifacts.require('MockSynthetixState')

// ["kovan, mainnet"]
const DEPLOY_TO_NETWORK = 'kovan'

module.exports = async function (deployer, network, accounts) {
  if (network === 'development') {
    return deployer
      .deploy(MockFeePool)
      .then((feePool) => {
        return deployer.deploy(MockExchangeRates).then((exchangeRates) => {
          return deployer.deploy(MockRewardEscrow).then((rewardEscrow) => {
            return deployer
              .deploy(MockSynthetixState)
              .then((synthetixState) => {
                const tokenInitialSupply = web3.utils.toWei('1000')

                return deployer
                  .deploy(MockSynthetix, tokenInitialSupply)
                  .then((synthetix) => {
                    return deployer
                      .deploy(
                        MockAddressResolver,
                        exchangeRates.address,
                        feePool.address,
                        rewardEscrow.address,
                        synthetixState.address,
                        synthetix.address,
                      )
                      .then(async (addressResolver) => {
                        return deployer.deploy(MockWETH).then((weth) => {
                          return deployer.deploy(MockUSDC).then((usdc) => {
                            return deployer
                              .deploy(
                                MockCollateralSet,
                                [weth.address, usdc.address],
                                weth.address,
                              )
                              .then((collateralSetToken) => {
                                return deployer
                                  .deploy(MockSUSD)
                                  .then((susd) => {
                                    return deployer
                                      .deploy(
                                        MockSetToken,
                                        [weth.address, usdc.address],
                                        collateralSetToken.address,
                                      )
                                      .then((setToken) => {
                                        const ETH_ADDRESS =
                                          '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE'
                                        return deployer
                                          .deploy(
                                            MockKyberProxy,
                                            ETH_ADDRESS,
                                            synthetix.address,
                                            susd.address,
                                            weth.address,
                                            usdc.address,
                                          )
                                          .then((kyberProxy) => {
                                            return deployer
                                              .deploy(
                                                MockRebalancingModule,
                                                setToken.address,
                                              )
                                              .then((rebalancingModule) => {
                                                const synthSymbols = [
                                                  'sETH',
                                                  'sUSD',
                                                ].map((symbol) =>
                                                  web3.utils.fromAscii(symbol),
                                                )
                                                const setComponentAddresses = [
                                                  weth.address,
                                                  usdc.address,
                                                ]
                                                return deployer
                                                  .deploy(
                                                    ExtTradeAccounting,
                                                    setToken.address,
                                                    synthSymbols,
                                                    setComponentAddresses,
                                                  )
                                                  .then(
                                                    async (tradeAccounting) => {
                                                      return deployer
                                                        .deploy(
                                                          xSNXCore,
                                                          tradeAccounting.address,
                                                          setToken.address,
                                                        )
                                                        .then(async (xsnx) => {
                                                          console.log(
                                                            'xsnx deployed',
                                                          )
                                                          await xsnx.setAddressResolverAddress(
                                                            addressResolver.address,
                                                          )
                                                          console.log(
                                                            'xsnx: address resolver set',
                                                          )
                                                          await xsnx.setSusdAddress(
                                                            susd.address,
                                                          )
                                                          console.log(
                                                            'xsnx: susd address set',
                                                          )
                                                          await xsnx.setSnxAddress(
                                                            synthetix.address,
                                                          )
                                                          console.log(
                                                            'xsnx: snx address set',
                                                          )
                                                          await xsnx.setRebalancingSetIssuanceModuleAddress(
                                                            rebalancingModule.address,
                                                          )
                                                          console.log(
                                                            'xsnx: rebalancing mod set',
                                                          )
                                                          await xsnx.approveTradeAccounting(
                                                            susd.address,
                                                          )
                                                          console.log(
                                                            'xsnx: susd => tradeAccounting approve',
                                                          )
                                                          await xsnx.approveTradeAccounting(
                                                            synthetix.address,
                                                          )
                                                          console.log(
                                                            'xsnx: snx => tradeAccounting approve',
                                                          )
                                                          await xsnx.approveTradeAccounting(
                                                            weth.address,
                                                          )
                                                          console.log(
                                                            'xsnx: set asset 1 => tradeAccounting approve',
                                                          )
                                                          await xsnx.approveTradeAccounting(
                                                            usdc.address,
                                                          )
                                                          console.log(
                                                            'xsnx: set asset 2 => tradeAccounting approve',
                                                          )

                                                          // only testing
                                                          await feePool.setSusdAddress(
                                                            susd.address,
                                                          )
                                                          // no direct interaction with transfer proxy.
                                                          // mockable?
                                                          // await xsnx.approveSetTransferProxy(
                                                          //   SET_ASSET_1,
                                                          //   SET_TRANSFER_PROXY,
                                                          // )
                                                          // console.log(
                                                          //   'xsnx: set asset 1 => transfer proxy approve',
                                                          // )
                                                          // await xsnx.approveSetTransferProxy(
                                                          //   SET_ASSET_2,
                                                          //   SET_TRANSFER_PROXY,
                                                          // )
                                                          // console.log(
                                                          //   'xsnx: set asset 2 => transfer proxy approve',
                                                          // )

                                                          await xsnx.setFee(
                                                            '286',
                                                          )
                                                          console.log(
                                                            'xsnx: fee divisor set',
                                                          )

                                                          await tradeAccounting.setCallerAddress(
                                                            xsnx.address,
                                                          )
                                                          console.log(
                                                            'ta: caller address set',
                                                          )
                                                          await tradeAccounting.setAddressResolverAddress(
                                                            addressResolver.address,
                                                          )
                                                          console.log(
                                                            'ta: address resolver set',
                                                          )

                                                          await tradeAccounting.setSynthetixStateAddress()
                                                          console.log(
                                                            'ta: synth state set',
                                                          )
                                                          await tradeAccounting.setExchangeRatesAddress()
                                                          console.log(
                                                            'ta: exch rates set',
                                                          )
                                                          await tradeAccounting.setSnxAddress(
                                                            synthetix.address,
                                                          )
                                                          console.log(
                                                            'ta: snx address set',
                                                          )
                                                          await tradeAccounting.setSusdAddress(
                                                            susd.address,
                                                          )
                                                          console.log(
                                                            'ta: susd address set',
                                                          )
                                                          await tradeAccounting.setKyberNetworkAddress(
                                                            kyberProxy.address,
                                                          )
                                                          console.log(
                                                            'ta: kyber proxy set',
                                                          )

                                                          await tradeAccounting.approveKyber(
                                                            synthetix.address,
                                                          )
                                                          console.log(
                                                            'ta: approve kyber: snx',
                                                          )
                                                          await tradeAccounting.approveKyber(
                                                            susd.address,
                                                          )
                                                          console.log(
                                                            'ta: approve kyber: susd',
                                                          )
                                                          await tradeAccounting.approveKyber(
                                                            weth.address,
                                                          )
                                                          console.log(
                                                            'ta: approve kyber: set asset 1',
                                                          )
                                                          await tradeAccounting.approveKyber(
                                                            usdc.address,
                                                          )
                                                          console.log(
                                                            'ta: approve kyber: set asset 2',
                                                          )
                                                        })
                                                    },
                                                  )
                                              })
                                          })
                                      })
                                  })
                              })
                          })
                        })
                      })
                  })
              })
          })
        })
      })
  }
  // ***********************************************************

  if (network === DEPLOY_TO_NETWORK) {
    console.log(`Deploying to ${network}...`)
    const [owner, user1] = accounts
    console.log('owner', owner)

    const SET_ADDRESS = migrationInputs['SET_ADDRESS'][network]
    const KYBER_PROXY = migrationInputs['KYBER_PROXY'][network]

    const SET_ASSET_1 = migrationInputs['SET_ASSET_1'][network]
    const SET_ASSET_2 = migrationInputs['SET_ASSET_2'][network]
    const ADDRESS_RESOLVER = migrationInputs['ADDRESS_RESOLVER'][network]

    const REBALANCING_MODULE = migrationInputs['REBALANCING_MODULE'][network]
    const SUSD_ADDRESS = migrationInputs['SUSD_ADDRESS'][network]
    const SNX_ADDRESS = migrationInputs['SNX_ADDRESS'][network]

    const SET_TRANSFER_PROXY = migrationInputs['SET_TRANSFER_PROXY'][network]
    const SYNTH_SYMBOLS = migrationInputs['SYNTH_SYMBOLS'][network].map((s) =>
      web3.utils.fromAscii(s),
    )
    const SET_COMPONENT_ADDRESSES = [SET_ASSET_1, SET_ASSET_2]

    return deployer
      .deploy(
        TradeAccounting,
        SET_ADDRESS,
        SYNTH_SYMBOLS,
        SET_COMPONENT_ADDRESSES,
      )
      .then((tradeAccounting) => {
        return deployer
          .deploy(xSNXCore, tradeAccounting.address, SET_ADDRESS)
          .then(async (xsnx) => {
            console.log('xsnx deployed')
            await xsnx.setAddressResolverAddress(ADDRESS_RESOLVER)
            console.log('xsnx: address resolver set')
            await xsnx.setSusdAddress(SUSD_ADDRESS)
            console.log('xsnx: susd address set')
            await xsnx.setSnxAddress(SNX_ADDRESS)
            console.log('xsnx: snx address set')
            await xsnx.setRebalancingSetIssuanceModuleAddress(
              REBALANCING_MODULE,
            )
            console.log('xsnx: rebalancing mod set')

            await xsnx.approveTradeAccounting(SUSD_ADDRESS)
            console.log('xsnx: susd => tradeAccounting approve')
            await xsnx.approveTradeAccounting(SNX_ADDRESS)
            console.log('xsnx: snx => tradeAccounting approve')
            await xsnx.approveTradeAccounting(SET_ASSET_1)
            console.log('xsnx: set asset 1 => tradeAccounting approve')
            await xsnx.approveTradeAccounting(SET_ASSET_2)
            console.log('xsnx: set asset 2 => tradeAccounting approve')

            await xsnx.approveSetTransferProxy(SET_ASSET_1, SET_TRANSFER_PROXY)
            console.log('xsnx: set asset 1 => transfer proxy approve')
            await xsnx.approveSetTransferProxy(SET_ASSET_2, SET_TRANSFER_PROXY)
            console.log('xsnx: set asset 2 => transfer proxy approve')

            await xsnx.setFee('286')
            console.log('xsnx: fee divisor set')

            await tradeAccounting.setCallerAddress(xsnx.address)
            console.log('ta: caller address set')
            await tradeAccounting.setAddressResolverAddress(ADDRESS_RESOLVER)
            console.log('ta: address resolver set')

            await tradeAccounting.setSynthetixStateAddress()
            console.log('ta: synth state set')
            await tradeAccounting.setExchangeRatesAddress()
            console.log('ta: exch rates set')
            await tradeAccounting.setSnxAddress(SNX_ADDRESS)
            console.log('ta: snx address set')
            await tradeAccounting.setSusdAddress(SUSD_ADDRESS)
            console.log('ta: susd address set')
            await tradeAccounting.setKyberNetworkAddress(KYBER_PROXY)
            console.log('ta: kyber proxy set')

            await tradeAccounting.approveKyber(SNX_ADDRESS)
            console.log('ta: approve kyber: snx')
            await tradeAccounting.approveKyber(SUSD_ADDRESS)
            console.log('ta: approve kyber: susd')
            await tradeAccounting.approveKyber(SET_ASSET_1)
            console.log('ta: approve kyber: set asset 1')
            await tradeAccounting.approveKyber(SET_ASSET_2)
            console.log('ta: approve kyber: set asset 2')
          })
      })
  }
}