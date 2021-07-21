//指定solidity的编译器版本
pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

//该行定义了本合约实现了IUniswapV2Pair并继承了UniswapV2ERC20，继承一个合约表明它继承了父合约的所有非私有的接口与状态变量
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    //指定库函数的应用类型
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    //定义了最小流动性。它是最小数值1的1000倍，用来在提供初始流动性时燃烧掉。
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    //用来计算标准ERC20合约中转移代币函数transfer的函数选择器。虽然标准的ERC20合约在转移代币后返回一个成功值，但有些不标准的并没有返回值。在这个合约里统一做了处理，并使用了较低级的call函数代替正常的合约调用。函数选择器用于call函数调用中。
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    //用来记录factory合约地址和交易对中两种代币的合约地址。注意它们是public的状态变量，意味着合约外可以直接使用同名函数获取对应的值。
    address public factory;
    address public token0;
    address public token1;

    //这三个状态变量记录了最新的恒定乘积中两种资产的数量和交易时的区块（创建）时间。
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    //记录交易对中两种价格的累计值
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    //记录某一时刻恒定乘积中积的值，主要用于开发团队手续费计算
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    //这段代码是用来防重入攻击的，在modifier（函数修饰器）中，_;代表执行被修饰的函数体。所以这里的逻辑很好理解，当函数（外部接口）被外部调用时，unlocked设置为0，函数执行完之后才会重新设置为1。在未执行完之前，这时如果重入该函数，lock修饰器仍然会起作用。这时unlocked仍然为0，无法通过修饰器中的require检查，整个交易会被重置。当然这里也可以不用0和1，也可以使用布尔类型true和false。
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    //用来获取当前交易对的资产信息及最后交易的区块时间
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    //使用call函数进行代币合约transfer的调用（使用了函数选择器）。注意，它检查了返回值（首先必须调用成功，然后无返回值或者返回值为true）
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    //这些event定义是为了方便客户端进行各种追踪的
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

   //constructor构造器，记录factory的合约地址
    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    //进行合约的初始化，因为factory合约使用create2函数创建交易对合约，无法向构造器传递参数，所以这里写了一个初始化函数用来记录合约中两种代币的地址
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    // 更新reserves，该函数的四个输入参数分别为当前合约两种代币余额及保存的恒定乘积中两种代币的数值。函数功能就是将保存的数值更新为实时代币余额，并同时进行价格累计的计算
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 验证余额值不能大于uint112类型的最大值，因为余额是uint256类型的
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        //因为一个存储插槽为256位，两个代币数量各112位，这样就是224位，只剩下32位没有用了，UniswapV2用它来记录当前的区块时间。因为区块时间是uint类型的，有可能超过uint32的最大值，所以对它取模，这样blockTimestamp的值就永远不会溢出了。但真实的时间值是会超过32位大小的，大约在02/07/2106，见其白皮书
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // 计算当前block时间和上一次block时间的差值。注释中提到已经考虑过溢出了
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 如果是同一个区块的第二笔及以后交易，timeElapsed就会为0，此时就不会计算价格累计值
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 计算两种价格的累积值
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //更新交易对中恒定乘积中的reserve的值，同时更新block时间为当前block时间（这样一个区块内价格只会累积计算一次）
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        // 触发同步事件，用于客户端追踪
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    // 计算并发送开发团队手续费的
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        //获取开发团队手续费地址，并根据该地址是否为零地址来判断开关是否打开
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        //使用一个局部变量记录过去某时刻的恒定乘积中的积的值。注释表明使用局部变量可以减少gas（估计是因为减少了状态变量操作）
        uint _kLast = kLast; // gas savings
        //如果手续费开关打开，计算手续费的值（手续费以增发该交易对合约流动性代币的方式体现）。可阅读其白皮书
        if (feeOn) {
            //开关打开后的第一次流动性操作只是建立了一个过去时刻的快照值kLast，第二次流动性操作才会有新的快照值，才能使用公式计算手续费。
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 核心合约对用户不友好，需要通过周边合约来间接交互
    // 在用户提供流动性时（提供一定比例的两种ERC20代币到交易对）增发流动性代币给提供者。
    // 注意流动性代币也是一种ERC20代币，是可以交易的，由此还衍生了一些其它类型的DeFi。函数的参数为接收流动性代币的地址，函数的返回值为增加的流动性数值
    function mint(address to) external lock returns (uint liquidity) {
        // 获取当前交易对的reverse
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        //在操作mint的之前，外围合约perophery中的addLiquidity 已经将token0和token1的币转到pairAddr了，如下
        //TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        //TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        //liquidity = IUniswapV2Pair(pair).mint(to);
        //用来获取当前合约注入的两种资产数量。注意UniswapV2采用了先转移代币，再调用合约的交易方式。因此，除了FlashSwap外，所有需要支付的代币都必须事先转移到交易对中。但是这样就不方便外部账号进行此类操作，一般是通过周边合约进行类似操作
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        // 发送开发团队手续费（如果相应开关打开的了话）
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 使用一个局部变量来保存已经发行流动性代币的总量。这样可以少操作状态变量，节省gas。注意，注释中提到了因为_mintFee函数可能更新已发行流动性代币的数量（具体在if (liquidity > 0) _mint(feeTo, liquidity);这一行代码），所以必须在它之后赋值
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        if (_totalSupply == 0) {
            // 如果是初次，其计算方法为恒定乘积公式中积的平方根，同时还需要燃烧掉部分最初始的流动性，具体数值为MINIMUM_LIQUIDITY
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 如果不是初次提供，则会根据已有流动性按比例增发。由于注入了两种代币，所以会有两个计算公式，每种代币按比例计算一次增发的流动性数量，取其中的最小值
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        // 增发的流动性必须大于0，等于0相当于无增发，白做无用功
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 增发新的流动性给接收者
        _mint(to, liquidity);//生成LP token 发送给流动性提供者，做市商

        // 更新当前保存的恒定乘积中两种资产的值
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果手续费打开了，更新最近一次的乘积值。该值不随平常的代币交易更新，仅用来流动性供给时计算开发团队手续费
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发一个增发事件让客户端追踪
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 通过燃烧流动性代币的形式来提取相应的两种资产，从而减小该交易对的流动性
    // 函数的参数为代币接收者的地址，返回值是提取的两种代币数量。注意，它需要事先将流动性代币转回交易对中
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        //外围合约已经将LP token转回给pairAddr了，removeLiquidity()如下：
        //IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        //(uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);


        // 前三行用来获取交易对的reverse及代币地址，并保存在局部变量中，注释中提到也是为了节省gas
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings

        // 获取交易对合约地址拥有两种代币的实际数量
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        // 获取事先转入的流动性的数值。正常情况下，交易对合约是没有任何流动性代币的。虽然它是发币合约，所有的流动性代币全在流动性提供者手里
        uint liquidity = balanceOf[address(this)];

        // 计算手续费，见mint函数。虽然提取资产并不涉及到流动性增发，但是这里还是要计算并发送手续费。如果仅在注入资产时计算并发送手续费，用户提取资产时就会计算不准确
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 按比例计算提取资产
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        // 将用户事先转入的流动性燃烧掉。因为此时流动性代币已经转移到交易对，所以燃烧的地址为address(this)
        _burn(address(this), liquidity);//销毁LP的币
        _safeTransfer(_token0, to, amount0);//从pairAddr的合约地址给to转token0的币
        _safeTransfer(_token1, to, amount1);//从pairAddr的合约地址给to转token1的币
        balance0 = IERC20(_token0).balanceOf(address(this));//更新pairAddr上的token0币的数量
        balance1 = IERC20(_token1).balanceOf(address(this));//更新pairAddr上的token1币的数量
        // 更新当前保存的恒定乘积中两种资产的值
        _update(balance0, balance1, _reserve0, _reserve1);
        // 更新KLast的值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发一个燃烧事件
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 实现交易对中资产（ERC20代币）交易的功能，也就两种ERC20代币互相买卖，而多个交易对可以组成一个交易链
    // 四个参数分别为购买的token0的数量，购买的token1的数量，接收者地址，接收后执行回调时的传递数据
    // amount0Out代表的是交易对中地址较小的代币
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 校验购买的数量必须小于reverse，否则没有那么多代币卖。根据恒定乘积计算公式，等于也是不行的，那样输入就是无穷大
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');
        // 定义了两个局部变量，它们来保存当前交易对的两种代币余额
        uint balance0;
        uint balance1;
        // 注意 组成一对{}，它是一个特殊的语法，注释说是用来避免堆栈过深错误。为什么会有堆栈过深错误呢，因为以太坊虚拟机（EVM）访问堆栈时最多只能访问16个插槽，当访问的插槽数超过16个时在编译时就会产生stack too deep errors。这个错误产生的原因也比较复杂（比如函数内参数、返回参数及局部变量过多，或者引用过深等），和部分操作码也有一定关联。但是这里应该是函数内局部变量过多引起的
        { // scope for _token{0,1}, avoids stack too deep errors
        // 使用两个局部变量记录token地址并验证接收者地址不能为token地址
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        // 先行转出购买资产
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        // 如果参数data不为空，那么执行调用合约的uniswapV2Call回调函数并将data传递过去，普通交易调用时这个data为空
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        // 获取交易对合约地址两种代币的余额并保存 
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 计算实际转移进来的代币数量
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // 对上面计算出来的数量进行验证，你必须转入某种资产（大于0）才能交易成另一种资产
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        // 进行最终的恒定乘积验证，V2版本的验证公式为：(x1 - 0.003 * xin) * (y1 - 0.003 * yin) >= x0 * y0，
        // 注意这里的x1和y1不是reserve,而是balance，而x0和y0是reserve。xin和yin为注入的资产数量，因此要扣除千分之三的交易手续费。这个公式的意思为新的恒定乘积的积必须大于旧的值，因为此时reserve未更新，所以使用的是balance，验证完成后reserve会更新为balance。xin和yin中任意一个为0，就变成V1版本的验证公式了
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }
        
        // 更新恒定乘积中的资产值reserve为balance
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    // 强制交易对合约中两种代币的实际余额和保存的恒定乘积中的资产数量一致（多余的发送给调用者）。注意：任何人都可以调用该函数来获取额外的资产（前提是如果存在多余的资产）
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    // 强制交易对合约中两种代币的实际余额和保存的恒定乘积中的资产数量一致（多余的发送给调用者）。注意：任何人都可以调用该函数来获取额外的资产（前提是如果存在多余的资产）
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
