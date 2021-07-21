const UniswapV2Router02 = artifacts.require("UniswapV2Router02");
const feeToSetter = '0xa39700d35cefac22f6364b9add8adc5aefb273f0';//设置手续费账户的管理员地址
const WETH = {
    mainnet:'0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    ropsten:'0xc778417E063141139Fce010982780140Aa0cD5Ab',
    rinkeby:'0xc778417E063141139Fce010982780140Aa0cD5Ab',
    goerli:'0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6',
    kovan:'0xd0A1E359811322d97991E03f863a0C30C2cF029C'
};
module.exports = (deployer, network, accounts) => {
    deployer.deploy(UniswapV2Router02,'0x4207CD6E113E364220EC08e2Ff446973437859fd',WETH[network]);
    
}
