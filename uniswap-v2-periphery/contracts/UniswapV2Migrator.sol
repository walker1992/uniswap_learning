pragma solidity =0.6.6;

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Migrator.sol';
import './interfaces/V1/IUniswapV1Factory.sol';
import './interfaces/V1/IUniswapV1Exchange.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IERC20.sol';

contract UniswapV2Migrator is IUniswapV2Migrator {
    IUniswapV1Factory immutable factoryV1;
    IUniswapV2Router01 immutable router;

    constructor(address _factoryV1, address _router) public {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        router = IUniswapV2Router01(_router);
    }

    // needs to accept ETH from any v1 exchange and the router. ideally this could be enforced, as in the router,
    // but it's not possible because it requires a call to the v1 factory, which takes too much gas
    receive() external payable {}

    // 本合约唯一对外接口，也是唯一功能。用来将UniswapV1交易对中的流动性迁移到V2交易对中。
    // 它的输入参数分别为：V1交易对中的ERC20代币地址（V1版本交易对中另一种资产为ETH），
    // 注入V2交易对的代币数量的下限值，注入V2交易对的ETH数量的下限值，接收V2交易对流动性的地址，最晚交易期限。该函数没有返回值
    function migrate(address token, uint amountTokenMin, uint amountETHMin, address to, uint deadline)
        external
        override
    {
        // 实例化V1版本的交易对
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(token));
        // 获取调用者在V1版本交易对的流动性
        uint liquidityV1 = exchangeV1.balanceOf(msg.sender);
        // 将V1交易对的流动性转移到本合约，注意这里因为非直接转移，所以需要事先授权。并且转移后必须返回true值
        require(exchangeV1.transferFrom(msg.sender, address(this), liquidityV1), 'TRANSFER_FROM_FAILED');
        // 调用V1交易对的removeLiquidity函数，移除调用者在第三行转过来的流动性，得到一种代币和ETH。这里V1版本的removeLiquidity函数的四个参数分别为：移除的流动性数量，得到的最小ETH数量，得到的最小代币数量，最后交易时间
        // 这里将得到的ETH及代币最小数量设置为最小值1，将最晚交易时间设置为了最大时间，是为了保证该交易能顺利进行，不受这些条件限制。返回值就是提取的ETH数量和另一种代币的数量。
        (uint amountETHV1, uint amountTokenV1) = exchangeV1.removeLiquidity(liquidityV1, 1, 1, uint(-1));
        // 将对Router1合约进行授权，授权的代币为token
        TransferHelper.safeApprove(token, address(router), amountTokenV1);
        (uint amountTokenV2, uint amountETHV2,) = router.addLiquidityETH{value: amountETHV1}(
            token,
            amountTokenV1,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
        if (amountTokenV1 > amountTokenV2) {
            TransferHelper.safeApprove(token, address(router), 0); // be a good blockchain citizen, reset allowance to 0
            TransferHelper.safeTransfer(token, msg.sender, amountTokenV1 - amountTokenV2);
        } else if (amountETHV1 > amountETHV2) {
            // addLiquidityETH guarantees that all of amountETHV1 or amountTokenV1 will be used, hence this else is safe
            TransferHelper.safeTransferETH(msg.sender, amountETHV1 - amountETHV2);
        }
    }
}
