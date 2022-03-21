// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/IMasterChef.sol";
import "../common/StratManager.sol";
import "../common/FeeManager.sol";
import "../../utils/StringUtils.sol";

contract StrategySharesLP is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public native;
    address public output;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public chef;
    uint256 public poolId;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;
    string public pendingRewardsFunctionName;

    // Routes
    address[] public outputToNativeRoute;
    address[] public outputToLp0Route;
    address[] public outputToLp1Route;

    // ======== PROTOCOL SUPPORT ITEMS ======== //

    // Main LP pool for protocol
    // AMES-UST
    address public protocolPairAddress;

    uint256 public protocolLpPoolId;

    // Token0 in main pair
    address public protocolLpToken0;

    // Token0 in main pair
    address public protocolLpToken1;

    // Routing path from output to Token0 in main pair
    address[] public protocolLp0Route;

    // Routing path from output to Token1 in main pair
    address[] public protocolLp1Route;

    event ProtocolLiquidity(
        uint256 indexed amountA,
        uint256 indexed amountB,
        uint256 indexed liquidity
    );

    event ProtocolLiquidityDeposit(uint256 indexed amount);

    event TreasuryTransfer(uint256 indexed amount);

    // ===== GENERAL EVENTS ===== //

    event StratHarvest(
        address indexed harvester,
        uint256 wantHarvested,
        uint256 tvl
    );
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);

    constructor(
        address _want,
        uint256 _poolId,
        address _chef,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _protocolFeeRecipient,
        address[] memory _outputToNativeRoute,
        address[] memory _outputToLp0Route,
        address[] memory _outputToLp1Route,
        address[] memory _protocolLp0Route,
        address[] memory _protocolLp1Route,
        address _protocolPairAddress,
        uint256 _protocolLpPoolId
    )
        public
        StratManager(
            _keeper,
            _strategist,
            _unirouter,
            _vault,
            _protocolFeeRecipient
        )
    {
        want = _want;
        poolId = _poolId;
        chef = _chef;

        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;

        // setup lp routing
        lpToken0 = IUniswapV2Pair(want).token0();
        require(
            _outputToLp0Route[0] == output,
            "outputToLp0Route[0] != output"
        );

        require(
            _outputToLp0Route[_outputToLp0Route.length - 1] == lpToken0,
            "outputToLp0Route[last] != lpToken0"
        );
        outputToLp0Route = _outputToLp0Route;

        lpToken1 = IUniswapV2Pair(want).token1();
        require(
            _outputToLp1Route[0] == output,
            "outputToLp1Route[0] != output"
        );

        require(
            _outputToLp1Route[_outputToLp1Route.length - 1] == lpToken1,
            "outputToLp1Route[last] != lpToken1"
        );
        outputToLp1Route = _outputToLp1Route;

        /**
            Protocol specific setup
         */

        require(_protocolPairAddress != address(0), "!_protocolPairAddress");

        protocolPairAddress = _protocolPairAddress;
        protocolLpPoolId = _protocolLpPoolId;

        protocolLpToken0 = IUniswapV2Pair(protocolPairAddress).token0();
        require(
            _protocolLp0Route[_protocolLp0Route.length - 1] == protocolLpToken0,
            "_protocolLp0Route[last] != protocolLpToken0"
        );
        protocolLp0Route = _protocolLp0Route;

        protocolLpToken1 = IUniswapV2Pair(protocolPairAddress).token1();
        require(
            _protocolLp1Route[_protocolLp1Route.length - 1] == protocolLpToken1,
            "_protocolLp1Route[last] != protocolLpToken0"
        );
        protocolLp1Route = _protocolLp1Route;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IMasterChef(chef).deposit(poolId, wantBal);
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMasterChef(chef).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(
                WITHDRAWAL_MAX
            );
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        // Harvest to setup compounding flow (charge fees -> compound rewards)
        IMasterChef(chef).deposit(poolId, 0);
        uint256 outputBal = IERC20(output).balanceOf(address(this));

        if (outputBal > 0) {
            // Charge fees on harvested rewards before compounding
            chargeFees(callFeeRecipient);

            addLiquidity();

            uint256 wantHarvested = balanceOfWant();

            deposit();

            lastHarvest = block.timestamp;

            emit StratHarvest(msg.sender, wantHarvested, balanceOf());
        }
    }

    /// @dev Used to charge fees on harvested rewards before executing the compounding process.
    function chargeFees(address callFeeRecipient) internal {
        // 4.5% fee
        uint256 rewardTokenBalance = IERC20(output)
            .balanceOf(address(this))
            .mul(45)
            .div(1000);

        // SET OUTPUT TO NATIVE TO UST..FJ'SFDL

        // Convert whatever the reward token is into the current chains native token
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(
            rewardTokenBalance,
            0,
            outputToNativeRoute,
            address(this),
            now
        );

        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE);
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);

        // Handle protocol items
        _handleTreasuryFee();
        _addProtocolLiquidity();
        _depositProtocolLP();
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        if (lpToken0 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                outputHalf,
                0,
                outputToLp0Route,
                address(this),
                now
            );
        }

        if (lpToken1 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                outputHalf,
                0,
                outputToLp1Route,
                address(this),
                now
            );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            now
        );
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(chef).userInfo(poolId, address(this));
        return _amount;
    }

    function setPendingRewardsFunctionName(
        string calldata _pendingRewardsFunctionName
    ) external onlyManager {
        pendingRewardsFunctionName = _pendingRewardsFunctionName;
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        string memory signature = StringUtils.concat(
            pendingRewardsFunctionName,
            "(uint256,address)"
        );
        bytes memory result = Address.functionStaticCall(
            chef,
            abi.encodeWithSignature(signature, poolId, address(this))
        );
        return abi.decode(result, (uint256));
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            try
                IUniswapRouterETH(unirouter).getAmountsOut(
                    outputBal,
                    outputToNativeRoute
                )
            returns (uint256[] memory amountOut) {
                nativeOut = amountOut[amountOut.length - 1];
            } catch {}
        }
        return nativeOut.mul(45).div(1000).mul(callFee).div(MAX_FEE);
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(chef).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IMasterChef(chef).emergencyWithdraw(poolId);
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(chef, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(chef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function outputToNative() external view returns (address[] memory) {
        return outputToNativeRoute;
    }

    function outputToLp0() external view returns (address[] memory) {
        return outputToLp0Route;
    }

    function outputToLp1() external view returns (address[] memory) {
        return outputToLp1Route;
    }

    /// @dev Allow updating to a more optimal routing path if needed
    function setOutputToLp0(address[] memory path) external onlyManager {
        require(path.length >= 2, "!path");

        outputToLp0Route = path;
    }

    /// @dev Allow updating to a more optimal routing path if needed
    function setOutputToLp1(address[] memory path) external onlyManager {
        require(path.length >= 2, "!path");

        outputToLp1Route = path;
    }

    /// @dev Allow updating to a more optimal routing path if needed
    function setOutputToNative(address[] memory path) external onlyManager {
        require(path.length >= 2, "!path");

        outputToNativeRoute = path;
    }

    // ======== PROTOCOL ITEMS ========== //

    function _handleTreasuryFee() private {
        uint256 nativeBal = IERC20(native).balanceOf(address(this));
        uint256 protocolFeeAmount = nativeBal.mul(protocolFee).div(MAX_FEE);

        // Split remaing native amount between treasury and providing LP
        uint256 amountToTreasury = protocolFeeAmount.div(2);

        // Trusted external call
        IERC20(native).safeTransfer(protocolFeeRecipient, amountToTreasury);

        emit TreasuryTransfer(amountToTreasury);
    }

    function _addProtocolLiquidity() private {
        uint256 nativeHalf = IERC20(native).balanceOf(address(this)).div(2);

        if (protocolLpToken0 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                nativeHalf,
                0,
                protocolLp0Route,
                address(this),
                now
            );
        }

        if (protocolLpToken1 != output) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                nativeHalf,
                0,
                protocolLp1Route,
                address(this),
                now
            );
        }

        uint256 lpBal0 = IERC20(protocolLpToken0).balanceOf(address(this));
        uint256 lpBal1 = IERC20(protocolLpToken1).balanceOf(address(this));

        (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        ) = IUniswapRouterETH(unirouter).addLiquidity(
                protocolLpToken0,
                protocolLpToken1,
                lpBal0,
                lpBal1,
                1,
                1,
                address(this),
                now
            );

        emit ProtocolLiquidity(amountA, amountB, liquidity);
    }

    function _depositProtocolLP() private {
        uint256 protocolLpBalance = IERC20(protocolPairAddress).balanceOf(
            address(this)
        );

        if (protocolLpBalance > 0) {
            IMasterChef(chef).deposit(protocolLpPoolId, protocolLpBalance);
            emit ProtocolLiquidityDeposit(protocolLpBalance);
        }
    }
}
