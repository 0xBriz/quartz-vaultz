// SPDX-License-Identifier: MIT
pragma solidity 0.6.12; 

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IStrategy.sol";

contract Vault is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct StratCandidate {
        address implementation;
        uint256 proposedTime;
    }

    // The last proposed strategy to switch to.
    StratCandidate public stratCandidate;

    // The strategy currently in use by the vault.
    IStrategy public strategy;

    // The minimum time it has to pass before a strat candidate can be approved.
    uint256 public immutable approvalDelay;

    event NewStratCandidate(address implementation);
    event UpgradeStrat(address implementation);

    /**
     * @dev Sets the value of {token} to the token that the vault will
     * hold as underlying value. It initializes the vault's own 'qd' token.
     * This token is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _strategy the address of the strategy.
     * @param _name the name of the vault token.
     * @param _symbol the symbol of the vault token.
     * @param _approvalDelay the delay before a new strat can be approved.
     */
    constructor(
        IStrategy _strategy,
        string memory _name,
        string memory _symbol,
        uint256 _approvalDelay
    ) public ERC20(_name, _symbol) {
        strategy = _strategy;
        approvalDelay = _approvalDelay;
    }

    function want() public view returns (IERC20) {
        return IERC20(strategy.want());
    }

    /**
     * @dev It calculates the total underlying value of {token} held by the system.
     * It takes into account the vault contract balance, the strategy contract balance
     *  and the balance deployed in other contracts as part of the strategy.
     */
    function balance() public view returns (uint256) {
        return
            want().balanceOf(address(this)).add(
                IStrategy(strategy).balanceOf()
            );
    }

    /**
     * @dev Custom logic in here for how much the vault allows to be borrowed.
     * We return 100% of tokens for now. Under certain conditions we might
     * want to keep some of the system funds at hand in the vault, instead
     * of putting them to work.
     */
    function available() public view returns (uint256) {
        return want().balanceOf(address(this));
    }

    /**
     * @dev Function for various UIs to display the current value of one of our yield tokens.
     * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() public view returns (uint256) {
        return
            totalSupply() == 0 ? 1e18 : balance().mul(1e18).div(totalSupply());
    }

    /**
     * @dev A helper function to call deposit() with all the sender's funds.
     */
    function depositAll() external {
        deposit(want().balanceOf(msg.sender));
    }

    /**
     * @dev The entrypoint of funds into the system. People deposit with this function
     * into the vault. The vault is then in charge of sending funds into the strategy.
     */
    function deposit(uint256 _amount) public nonReentrant {
        // Allow any setup steps implemented in strategy to run first
        strategy.beforeDeposit();

        // Get current total holdings amount (vault and strat)
        uint256 _pool = balance();

        // Pull callers tokens to vault
        want().safeTransferFrom(msg.sender, address(this), _amount);

        // Transfer current available `want` amount to strategy and call its `deposit` function after.
        earn();

        // Run checks after transfer into the strategy to determine vault token mint amount
        uint256 _after = balance();
        // Additional check for deflationary tokens
        _amount = _after.sub(_pool);

        uint256 shares = 0;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalSupply())).div(_pool);
        }

        _mint(msg.sender, shares);
    }

    /**
     * @dev Function to send funds into the strategy and put them to work. It's primarily called
     * by the vault's deposit() function.
     */
    function earn() public {
        uint256 _bal = available();
        want().safeTransfer(address(strategy), _bal);
        strategy.deposit();
    }

    /**
     * @dev A helper function to call withdraw() with all the sender's funds.
     */
    function withdrawAll() external {
        withdraw(balanceOf(msg.sender));
    }

    /**
     * @dev Function to exit the system. The vault will withdraw the required tokens
     * from the strategy and pay up the token holder. A proportional number of IOU
     * tokens are burned in the process.
     */
    function withdraw(uint256 _shares) public {
        uint256 r = (balance().mul(_shares)).div(totalSupply());
        _burn(msg.sender, _shares);

        uint256 b = want().balanceOf(address(this));
        if (b < r) {
            uint256 _withdraw = r.sub(b);
            strategy.withdraw(_withdraw);
            uint256 _after = want().balanceOf(address(this));
            uint256 _diff = _after.sub(b);
            if (_diff < _withdraw) {
                r = b.add(_diff);
            }
        }

        want().safeTransfer(msg.sender, r);
    }

    /**
     * @dev Sets the candidate for the new strat to use with this vault.
     * @param _implementation The address of the candidate strategy.
     */
    function proposeStrat(address _implementation) public onlyOwner {
        require(
            address(this) == IStrategy(_implementation).vault(),
            "Proposal not valid for this Vault"
        );
        stratCandidate = StratCandidate({
            implementation: _implementation,
            proposedTime: block.timestamp
        });

        emit NewStratCandidate(_implementation);
    }

    /**
     * @dev It switches the active strat for the strat candidate. After upgrading, the
     * candidate implementation is set to the 0x00 address, and proposedTime to a time
     * happening in +100 years for safety.
     */

    function upgradeStrat() public onlyOwner {
        require(
            stratCandidate.implementation != address(0),
            "There is no candidate"
        );
        require(
            stratCandidate.proposedTime.add(approvalDelay) < block.timestamp,
            "Delay has not passed"
        );

        emit UpgradeStrat(stratCandidate.implementation);

        strategy.retireStrat();
        strategy = IStrategy(stratCandidate.implementation);
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;

        earn();
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param _token address of the token to rescue.
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != address(want()), "!token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
}
