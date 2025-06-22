// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IPancakeRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint, uint, uint);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract ATC is ERC20, Ownable, ReentrancyGuard {
    IPancakeRouter public router;
    address public pair;

    // Tax structure (25% total)
    uint256 public constant BUY_TAX = 2500; // 25%
    uint256 public constant SELL_TAX = 2500; // 25%
    uint256 private constant TAX_DENOMINATOR = 10000;

    // Tax distribution
    uint256 public lpTax = 500;     // 5% of 25%
    uint256 public devTax = 1000;   // 10% of 25%
    uint256 public artistTax = 500; // 5% of 25%
    uint256 public marketingTax = 500; // 5% of 25%

    // Wallets
    address public devWallet;
    address public artistWallet;
    address public marketingWallet;

    // Swap settings
    uint256 public swapThreshold = 50_000 * 10**18;
    bool private swapping;

    // Trading control
    bool public tradingEnabled;
    mapping(address => bool) public isExcludedFromFee;

    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiquidity);

    constructor() ERC20("Automator Coin", "ATC") Ownable(msg.sender) {
        _mint(msg.sender, 1_000_000_000 * 10**18);

        // Initialize PancakeSwap
        router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        pair = IPancakeFactory(router.factory()).createPair(address(this), router.WETH());

        // Set wallets
        devWallet = 0x73aDd9B0Fae851F9f203Ba5346D240C32d5af259;
        artistWallet = 0xfbd336B10D3Aa003bB0491277bd1b100a7600b7A;
        marketingWallet = 0xc5e979514ebE80172EdBa7c7cfE38B599E4e4823;

        // Exclude owner and this contract and wallets from fee
        isExcludedFromFee[msg.sender] = true;
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[devWallet] = true;
        isExcludedFromFee[artistWallet] = true;
        isExcludedFromFee[marketingWallet] = true;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _customTransfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(sender, spender, amount);
        _customTransfer(sender, recipient, amount);
        return true;
    }

    function _customTransfer(address sender, address recipient, uint256 amount) internal nonReentrant {
        require(amount > 0, "Transfer amount must be greater than zero");
        require(tradingEnabled || isExcludedFromFee[sender] || isExcludedFromFee[recipient], "Trading not enabled");

        uint256 taxAmount = 0;

        if(!isExcludedFromFee[sender] && !isExcludedFromFee[recipient]) {
            if(recipient == pair) { // Sell
                taxAmount = (amount * SELL_TAX) / TAX_DENOMINATOR;
            } else if(sender == pair) { // Buy
                taxAmount = (amount * BUY_TAX) / TAX_DENOMINATOR;
            }
            
            if(taxAmount > 0) {
                uint256 lpTokens = (taxAmount * lpTax) / SELL_TAX;
                uint256 devTokens = (taxAmount * devTax) / SELL_TAX;
                uint256 artistTokens = (taxAmount * artistTax) / SELL_TAX;
                uint256 marketingTokens = taxAmount - lpTokens - devTokens - artistTokens;

                super._transfer(sender, address(this), lpTokens);
                super._transfer(sender, devWallet, devTokens);
                super._transfer(sender, artistWallet, artistTokens);
                super._transfer(sender, marketingWallet, marketingTokens);

                amount -= taxAmount;

                if(recipient == pair && balanceOf(address(this)) >= swapThreshold && !swapping) {
                    swapAndLiquify();
                }
            }
        }

        super._transfer(sender, recipient, amount);
    }

    function swapAndLiquify() private {
        swapping = true;
        uint256 contractBalance = balanceOf(address(this));
        uint256 half = contractBalance / 2;
        uint256 otherHalf = contractBalance - half;

        // Corrected path array declaration
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH(); // Fixed from METM to WETH

        uint256 initialBNB = address(this).balance;

        _approve(address(this), address(router), half);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half, 0, path, address(this), block.timestamp
        );

        uint256 newBNB = address(this).balance - initialBNB;

        _approve(address(this), address(router), otherHalf);
        router.addLiquidityETH{value: newBNB}(
            address(this),
            otherHalf,
            0,
            0,
            0x000000000000000000000000000000000000dEaD,
            block.timestamp
        );

        emit SwapAndLiquify(half, newBNB, otherHalf);
        swapping = false;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
    }

    function updateWallets(address _dev, address _artist, address _marketing) external onlyOwner {
        devWallet = _dev;
        artistWallet = _artist;
        marketingWallet = _marketing;
        isExcludedFromFee[devWallet] = true;
        isExcludedFromFee[artistWallet] = true;
        isExcludedFromFee[marketingWallet] = true;
    }

    function setExcludedFromFee(address account, bool excluded) external onlyOwner {
        isExcludedFromFee[account] = excluded;
    }

    function setSwapThreshold(uint256 amount) external onlyOwner {
        swapThreshold = amount;
    }

    function withdrawStuckTokens(address token) external onlyOwner {
        require(token != address(this), "Cannot withdraw ATC");
        IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }

    receive() external payable {}
}