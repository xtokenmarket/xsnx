const synthetix = require('synthetix')

const deployment = 'ETHRSI6040'
// const deployment = "LINKETHRSI"

const isEthRsi6040 = deployment === 'ETHRSI6040'

const migrationInputs = {
  SET_ADDRESS: {
    kovan: '0x76f579bb28a470913AbE98fc9d76145c26839af7', // LINKETHRSI
    mainnet: isEthRsi6040 ? '' : '',
  },
  SET_ASSET_1: {
    kovan: '0x8a18c7034acefd1748199a58683ee5f22e2d4e45', // WETH
    mainnet: isEthRsi6040 ? '' : '',
  },
  SET_ASSET_2: {
    kovan: '0x61eB5a373c4Ec78523602583c049d8563d2C7BCD', // LINK
    mainnet: isEthRsi6040 ? '' : '',
  },
  KYBER_PROXY: {
    kovan: '0x692f391bCc85cefCe8C237C01e1f636BbD70EA4D',
    mainnet: '',
  },
  ADDRESS_RESOLVER: {
    kovan: synthetix.getTarget({
      network: 'kovan',
      contract: 'ReadProxyAddressResolver',
    }).address,
    mainnet: '',
  },
  REBALANCING_MODULE: {
    kovan: '0x91E1489D04054Ae552a369504F94E0236909c53c',
    mainnet: '',
  },
  CURVE_POOL: {
    kovan: '0x1daB6560494B04473A0BE3E7D83CF3Fdf3a51828',
    mainnet: '0xA5407eAE9Ba41422680e2e00537571bcC53efBfD',
  },
  SUSD_ADDRESS: {
    kovan: synthetix.getTarget({ network: 'kovan', contract: 'ProxyERC20sUSD' })
      .address,
    mainnet: '',
  },
  SNX_ADDRESS: {
    kovan: synthetix.getTarget({ network: 'kovan', contract: 'ProxyERC20' })
      .address,
    mainnet: '',
  },
  USDC_ADDRESS: {
    kovan: '0xA91FDf706d8675eE43E5Ac4cBDb5d615bd5921a8',
    mainnet: ''
  },
  SET_TRANSFER_PROXY: {
    kovan: '0x61d264865756751392C0f00357Cc26ea70D98E3B',
    mainnet: '',
  },
  SYNTH_SYMBOLS: {
    kovan: ['sETH', 'sLINK'],
    mainnet: isEthRsi6040 ? [] : [],
  },
}

module.exports = migrationInputs
