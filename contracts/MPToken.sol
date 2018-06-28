pragma solidity 0.4.24;

import "./StandardToken.sol";

contract MPToken is StandardToken {
    string public constant name = "MPToken";
    string public constant symbol = "MPT";
    uint8 public constant decimals = 18;

    uint256 public constant INITIAL_SUPPLY = 10000 * (10 ** uint256(decimals));

    constructor() public {
        totalSupply_ = INITIAL_SUPPLY;
        balances[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }
}