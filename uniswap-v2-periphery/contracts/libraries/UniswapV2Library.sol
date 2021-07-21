pragma solidity >=0.5.0;

// 导入IUniswapV2Pair.sol，也就是交易对的接口，注意它是使用Node.js的module导入的 需要 npm i --save @uniswap/v2-core 安装
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
// 导入SafeMath，注意它是正常使用相对路径导入的
import "./SafeMath.sol";

// 库定义
library UniswapV2Library {
    // 在Uint类型上使用SafeMath
    using SafeMath for uint;

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    // 对地址进行从小到大排序并验证不能为零地址
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    // 计算生成的交易对的地址的。具体计算方法可以分为链下计算和链上合约计算
    // init_code_hash: INIT_CODE_HASH = keccak256(['bytes'], [`0x${bytecode}`]) 见：https://github.com/Uniswap/uniswap-v2-periphery/issues/59
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }

    // fetches and sorts the reserves for a pair
    // 获取某个交易对中恒定乘积的各资产的值。因为返回的资产值是排序过的，而输入参数是不会有排序的，所以函数的最后一行做了处理
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    // 根据比例由一种资产计算另一种资产的值
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    /*
    A/B交易对中卖出A资产，计算买进的B资产的数量。注意，卖出的资产扣除了千之分三的交易手续费。其计算公式为：
    初始条件 A * B = K
    交易后条件 ( A + A0 ) * ( B - B0 ) = k
    计算得到 B0 = A0 * B / ( A + A0)
    考虑千分之三的手续费，将上式中的两个A0使用997 * A0 /1000代替，最后得到结果为 B0 = 997 * A0 * B / (1000 * A + 997 * A0 )
    */
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    /*
    A/B交易对中买进B资产，计算卖出的A资产的数量。注意，它也考虑了手续费。它和getAmountOut函数的区别是一个指定卖出的数量，一个是指定买进的数量。因为是恒定乘积算法，价格是非线性的，所以会有两种计算方式。其计算公式为：
    初始条件 A * B = K
    交易后条件 ( A + A0 ) * ( B - B0 ) = k
    计算得到 A0 = A * B0 / ( B - B0)
    考虑千分之三的手续费，A0 = A0 * 1000 / 997，所以计算结果为 A0 = A * B0 * 1000 / (( B - B0 ) * 997)
    因为除法是地板除，但是卖进的资产不能少（可以多一点），所以最后结果还需要再加上一个1
    */ 
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    // 计算链式交易中卖出某资产，得到的中间资产和最终资产的数量。例如 A/B => B/C 卖出A，得到BC的数量
    function getAmountsOut(address factory, uint amountIn, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    // 计算链式交易中买进某资产，需要卖出的中间资产和初始资产数量。例如 A/B => B/C 买进C，得到AB的数量。因为从买进推导卖出是反向进行的，所以数据是反向遍历的
    function getAmountsIn(address factory, uint amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
