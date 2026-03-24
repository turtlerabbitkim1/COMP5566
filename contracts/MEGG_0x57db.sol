// SPDX-License-Identifier: MIT
/*
Megg is the main character of Megg, Mogg & Owl by Simon Hanselmann — an underground comic born from the same early internet culture that created Pepe the Frog.
Just like Boys Club, Megg and her crew drift through life on a couch — lost in smoke, chaos, and absurdity.
First it was Pepe.
Now it’s her turn.

Twitter/X: https://x.com/megg_coin

Telegram: https://t.me/Megg_Eth

Website: https://meggcoin.com/

*/
pragma solidity ^0.8.23;

// ─── Uniswap interfaces ───────────────────────────────────────────────────────

interface IFactory {
    function createPair(address a, address b) external returns (address);
}

interface IRouter {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

// ─── ERC20 interface ──────────────────────────────────────────────────────────

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amt) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amt) external returns (bool);
    function transferFrom(address from, address to, uint256 amt) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// ─── Ownership ────────────────────────────────────────────────────────────────

contract Administered {
    address private _admin;

    event AdminTransferred(address indexed from, address indexed to);

    constructor() {
        _admin = msg.sender;
        emit AdminTransferred(address(0), _admin);
    }

    function admin() public view returns (address) {
        return _admin;
    }

    modifier restricted() {
        require(msg.sender == _admin, "Restricted");
        _;
    }

    function surrenderAdmin() external restricted {
        emit AdminTransferred(_admin, address(0));
        _admin = address(0);
    }
}

// ─── Main token contract ──────────────────────────────────────────────────────

contract MEGG is IERC20, Administered {

    // --- Token config ---
    string  private constant _name     = unicode"Megg";
    string  private constant _symbol   = unicode"MEGG";
    uint8   private constant _decimals = 9;
    uint256 private constant _supply   = 1_000_000_000 * 10 ** _decimals;

    // --- Balances & approvals ---
    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _apr;

    // --- Access control ---
    mapping(address => bool) private _noFee;
    mapping(address => bool) private _frozen;

    // --- Fee receiver ---
    address payable private immutable _sink;

    // --- Trading state ---
    bool private _open    = false;
    bool private _locking = false;

    // --- Uniswap ---
    IRouter  private immutable _dex;
    address  private _pool;

    // --- Swap config ---
    uint256 private constant _earlyFee     = 16;   // % fee during early buys
    uint256 private constant _lateFee      = 0;    // % fee after threshold
    uint256 private constant _feeThreshold = 21;   // buy count where fee drops
    uint256 private constant _swapAfter    = 22;   // buys before swap activates
    uint256 private constant _swapCap      = 10;   // swapMax = 1% (10/1000 of supply)
    uint256 private constant _swapFloor    = 1;    // swapMin = 0.1% (1/1000 of supply)
    uint256 private constant _blockSellCap = 5;    // max swap sells per block

    // --- Limits ---
    uint256 public _txCap     = (_supply * 2) / 100;
    uint256 public _walletCap = (_supply * 2) / 100;

    // --- Counters ---
    uint256 private _buys          = 0;
    uint256 private _blockSells    = 0;
    uint256 private _lastSellBlock = 0;

    // --- Events ---
    event TradingOpened();
    event LimitsRemoved();

    // --- Reentrancy guard ---
    modifier noReentry() {
        _locking = true;
        _;
        _locking = false;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        _sink = payable(0x255eDbeCbe194Dc0c25CE4F6d8F10daA161ca074);
        _dex  = IRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

        _bal[msg.sender] = _supply;

        // Fee exemptions
        _noFee[msg.sender]      = true;
        _noFee[address(this)]   = true;
        _noFee[_sink]           = true;

        emit Transfer(address(0), msg.sender, _supply);
    }

    // ─── ERC20 views ─────────────────────────────────────────────────────────

    function name()        public pure returns (string memory) { return _name; }
    function symbol()      public pure returns (string memory) { return _symbol; }
    function decimals()    public pure returns (uint8)         { return _decimals; }
    function totalSupply() public pure override returns (uint256) { return _supply; }

    function balanceOf(address who) public view override returns (uint256) {
        return _bal[who];
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _apr[owner][spender];
    }

    // ─── ERC20 actions ───────────────────────────────────────────────────────

    function approve(address spender, uint256 amt) public override returns (bool) {
        _grant(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        require(_apr[from][msg.sender] >= amt, "Allowance too low");
        _apr[from][msg.sender] -= amt;
        _move(from, to, amt);
        return true;
    }

    // ─── Internal: approve ───────────────────────────────────────────────────

    function _grant(address owner, address spender, uint256 amt) private {
        require(owner   != address(0), "Bad owner");
        require(spender != address(0), "Bad spender");
        _apr[owner][spender] = amt;
        emit Approval(owner, spender, amt);
    }

    // ─── Internal: helpers ───────────────────────────────────────────────────

    function _smallest(uint256 x, uint256 y) private pure returns (uint256) {
        return x < y ? x : y;
    }

    function _currentFee(bool isBuy) private view returns (uint256) {
        if (isBuy)  return _buys > _feeThreshold ? _lateFee : _earlyFee;
        return _buys > _feeThreshold ? _lateFee : _earlyFee;
    }

    function _swapMax() private pure returns (uint256) {
        return (_supply * _swapCap)   / 1000;
    }

    function _swapMin() private pure returns (uint256) {
        return (_supply * _swapFloor) / 1000;
    }

    // ─── Internal: swap swap ─────────────────────────────────────────────────

    function _swapExecute(uint256 cap) private noReentry {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _dex.WETH();
        _grant(address(this), address(_dex), cap);
        _dex.swapExactTokensForETHSupportingFeeOnTransferTokens(
            cap, 0, path, address(this), block.timestamp
        );
        if (address(this).balance > 0) {
            _sink.transfer(address(this).balance);
        }
    }

    // ─── Internal: core transfer ─────────────────────────────────────────────

    function _move(address from, address to, uint256 amt) private {
        require(from != address(0) && to != address(0), "Bad address");
        require(amt > 0, "Zero amount");

        uint256 cut = 0;

        if (!_noFee[from] && !_noFee[to]) {
            require(!_frozen[from] && !_frozen[to], "Address frozen");

            bool isBuy  = (from == _pool);
            bool isSell = (to   == _pool);

            // Buy path
            if (isBuy && to != address(_dex)) {
                require(amt <= _txCap,                        "Over tx limit");
                require(_bal[to] + amt <= _walletCap,         "Over wallet limit");
                cut = (amt * _currentFee(true)) / 100;
                _buys++;
            }

            // Sell path
            if (isSell && from != address(this)) {
                cut = (amt * _currentFee(false)) / 100;
            }

            // Swap mechanism — triggers on sells after enough buys
            uint256 pooled = _bal[address(this)];
            if (
                isSell          &&
                !_locking       &&
                _open           &&
                _buys > _swapAfter &&
                pooled > _swapMin()
            ) {
                if (block.number > _lastSellBlock) {
                    _blockSells = 0;
                }
                require(_blockSells < _blockSellCap, "Block sell cap hit");
                uint256 swapAmt = _smallest(amt, _smallest(pooled, _swapMax()));
                _swapExecute(swapAmt);
                _blockSells++;
                _lastSellBlock = block.number;
            }
        }

        // Apply cut
        if (cut > 0) {
            _bal[address(this)] += cut;
            emit Transfer(from, address(this), cut);
        }

        _bal[from] -= amt;
        _bal[to]   += (amt - cut);
        emit Transfer(from, to, amt - cut);
    }

    // ─── Owner: open trading ─────────────────────────────────────────────────

    function openTrading() external restricted {
        require(!_open, "Already open");

        // Create pool
        _pool = IFactory(_dex.factory()).createPair(address(this), _dex.WETH());
        IERC20(_pool).approve(address(_dex), type(uint256).max);

        // Add liquidity with everything in contract
        _grant(address(this), address(_dex), _supply);
        _dex.addLiquidityETH{value: address(this).balance}(
            address(this),
            _bal[address(this)],
            0, 0,
            admin(),
            block.timestamp
        );

        _open = true;
        emit TradingOpened();
    }

    // ─── Owner: recover ETH before launch ────────────────────────────────────

    function recoverETH() external restricted {
        require(!_open, "Already open");
        payable(admin()).transfer(address(this).balance);
    }

    // ─── Owner: remove limits ────────────────────────────────────────────────

    function removeLimits() external restricted {
        _txCap     = _supply;
        _walletCap = _supply;
        emit LimitsRemoved();
    }

    // ─── Owner: blacklist ─────────────────────────────────────────────────────

    function freezeWallets(address[] calldata wallets) external restricted {
        for (uint256 i = 0; i < wallets.length; i++) {
            _frozen[wallets[i]] = true;
        }
    }

    function unfreezeWallets(address[] calldata wallets) external restricted {
        for (uint256 i = 0; i < wallets.length; i++) {
            _frozen[wallets[i]] = false;
        }
    }

    function isFrozen(address wallet) external view returns (bool) {
        return _frozen[wallet];
    }

    // ─── Treasury: manual controls ───────────────────────────────────────────

    function manualSwap() external {
        require(msg.sender == _sink, "Not sink");
        uint256 tokens = _bal[address(this)];
        if (tokens > 0) _swapExecute(tokens);
    }

    function manualSend() external {
        require(msg.sender == _sink, "Not sink");
        if (address(this).balance > 0) _sink.transfer(address(this).balance);
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────────

    receive() external payable {}
}