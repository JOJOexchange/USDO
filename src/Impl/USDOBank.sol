/*
    Copyright 2022 JOJO Exchange
    SPDX-License-Identifier: Apache-2.0*/
pragma solidity 0.8.9;

import "../Interface/IUSDOBank.sol";
import "../Interface/IFlashLoanReceive.sol";
import "./USDOBankStorage.sol";
import "./USDOOperation.sol";
import "./USDOView.sol";
import "./USDOMulticall.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@JOJO/contracts/intf/IDealer.sol";
import { IPriceChainLink } from "../Interface/IPriceChainLink.sol";

contract USDOBank is IUSDOBank, USDOOperation, USDOView, USDOMulticall {
    using DecimalMath for uint256;
    using SafeERC20 for IERC20;

    constructor(
        uint256 _maxReservesNum,
        address _insurance,
        address _USDO,
        address _JOJODealer,
        uint256 _maxPerAccountBorrowAmount,
        uint256 _maxTotalBorrowAmount,
        uint256 _borrowFeeRate,
        address _primaryAsset
    ) {
        maxReservesNum = _maxReservesNum;
        USDO = _USDO;
        JOJODealer = _JOJODealer;
        insurance = _insurance;
        maxPerAccountBorrowAmount = _maxPerAccountBorrowAmount;
        maxTotalBorrowAmount = _maxTotalBorrowAmount;
        borrowFeeRate = _borrowFeeRate;
        t0Rate = JOJOConstant.ONE;
        primaryAsset = _primaryAsset;
        lastUpdateTimestamp = uint32(block.timestamp);
    }

    // --------------------------event-----------------------

    event HandleBadDebt(address indexed liquidatedTrader, uint256 borrowUSDOT0);
    event Deposit(
        address indexed collateral, address indexed from, address indexed to, address operator, uint256 amount
    );
    event Borrow(address indexed from, address indexed to, uint256 amount, bool isDepositToJOJO);
    event Repay(address indexed from, address indexed to, uint256 amount);
    event Withdraw(address indexed collateral, address indexed from, address indexed to, uint256 amount);
    event Liquidate(
        address indexed collateral,
        address indexed liquidator,
        address indexed liquidated,
        address operator,
        uint256 collateralAmount,
        uint256 liquidatedAmount,
        uint256 insuranceFee
    );
    event FlashLoan(address indexed collateral, uint256 amount);

    /// @notice to ensure msg.sender is from account or msg.sender is the sub account of from
    /// so that msg.sender can send the transaction
    modifier isValidOperator(address operator, address client) {
        require(msg.sender == client || operatorRegistry[client][operator], USDOErrors.CAN_NOT_OPERATE_ACCOUNT);
        _;
    }

    function deposit(
        address from,
        address collateral,
        uint256 amount,
        address to
    ) external override nonReentrant isValidOperator(msg.sender, from) {
        DataTypes.ReserveInfo storage reserve = reserveInfo[collateral];
        DataTypes.UserInfo storage user = userInfo[to];
        //        deposit
        _deposit(reserve, user, amount, collateral, to, from);
    }

    function borrow(uint256 amount, address to, bool isDepositToJOJO) external override nonReentrant {
        //     t0BorrowedAmount = borrowedAmount /  getT0Rate
        DataTypes.UserInfo storage user = userInfo[msg.sender];
        _borrow(user, isDepositToJOJO, to, amount, msg.sender);
        require(_isAccountSafe(user, getTRate()), USDOErrors.AFTER_BORROW_ACCOUNT_IS_NOT_SAFE);
    }

    function repay(uint256 amount, address to) external override nonReentrant returns (uint256) {
        DataTypes.UserInfo storage user = userInfo[to];
        uint256 tRate = getTRate();
        return _repay(user, msg.sender, to, amount, tRate);
    }

    function withdraw(address collateral, uint256 amount, address to, bool isInternal) external override nonReentrant {
        DataTypes.UserInfo storage user = userInfo[msg.sender];
        _withdraw(amount, collateral, to, msg.sender, isInternal);
        uint256 tRate = getTRate();
        require(_isAccountSafe(user, tRate), USDOErrors.AFTER_WITHDRAW_ACCOUNT_IS_NOT_SAFE);
    }

    function liquidate(
        address liquidated,
        address collateral,
        address liquidator,
        uint256 amount,
        bytes memory afterOperationParam,
        uint256 expectAmount
    )
        external
        override
        isValidOperator(msg.sender, liquidator)
        returns (DataTypes.LiquidateData memory liquidateData)
    {
        uint256 USDOBorrowedT0 = userInfo[liquidated].t0BorrowBalance;
        uint256 primaryLiquidatedAmount = IERC20(primaryAsset).balanceOf(liquidated);
        uint256 primaryInsuranceAmount = IERC20(primaryAsset).balanceOf(insurance);
        require(liquidator != liquidated, USDOErrors.SELF_LIQUIDATION_NOT_ALLOWED);
        // 1. calculate the liquidate amount
        liquidateData = _calculateLiquidateAmount(liquidated, collateral, amount);
        require(liquidateData.actualCollateral >= expectAmount, USDOErrors.LIQUIDATION_PRICE_PROTECTION);
        // 2. after liquidation flashloan operation
        _afterLiquidateOperation(afterOperationParam, amount, collateral, liquidated, liquidateData);

        // 3. price protect
        require(
            USDOBorrowedT0 - userInfo[liquidated].t0BorrowBalance >= liquidateData.actualLiquidatedT0,
            USDOErrors.REPAY_AMOUNT_NOT_ENOUGH
        );
        require(
            IERC20(primaryAsset).balanceOf(insurance) - primaryInsuranceAmount >= liquidateData.insuranceFee,
            USDOErrors.INSURANCE_AMOUNT_NOT_ENOUGH
        );
        require(
            IERC20(primaryAsset).balanceOf(liquidated) - primaryLiquidatedAmount >= liquidateData.liquidatedRemainUSDC,
            USDOErrors.LIQUIDATED_AMOUNT_NOT_ENOUGH
        );
        emit Liquidate(
            collateral,
            liquidator,
            liquidated,
            msg.sender,
            liquidateData.actualCollateral,
            liquidateData.actualLiquidated,
            liquidateData.insuranceFee
        );
        // 4. handle the bad debt
        if (userInfo[liquidated].collateralList.length == 0) {
            _handleBadDebt(liquidated);
        }
    }

    function handleDebt(address[] calldata liquidatedTraders) external onlyOwner {
        for (uint256 i; i < liquidatedTraders.length; i = i + 1) {
            _handleBadDebt(liquidatedTraders[i]);
        }
    }

    function flashLoan(
        address receiver,
        address collateral,
        uint256 amount,
        address to,
        bytes memory param
    ) external nonFlashLoanReentrant {
        DataTypes.UserInfo storage user = userInfo[msg.sender];
        _withdraw(amount, collateral, receiver, msg.sender, false);
        // repay
        IFlashLoanReceive(receiver).JOJOFlashLoan(collateral, amount, to, param);
        require(_isAccountSafe(user, getTRate()), USDOErrors.AFTER_FLASHLOAN_ACCOUNT_IS_NOT_SAFE);
        emit FlashLoan(collateral, amount);
    }

    function _deposit(
        DataTypes.ReserveInfo storage reserve,
        DataTypes.UserInfo storage user,
        uint256 amount,
        address collateral,
        address to,
        address from
    ) internal {
        require(reserve.isDepositAllowed, USDOErrors.RESERVE_NOT_ALLOW_DEPOSIT);
        require(amount != 0, USDOErrors.DEPOSIT_AMOUNT_IS_ZERO);
        IERC20(collateral).safeTransferFrom(from, address(this), amount);
        if (user.depositBalance[collateral] == 0) {
            user.collateralList.push(collateral);
        }
        user.depositBalance[collateral] += amount;
        reserve.totalDepositAmount += amount;
        require(
            user.depositBalance[collateral] <= reserve.maxDepositAmountPerAccount,
            USDOErrors.EXCEED_THE_MAX_DEPOSIT_AMOUNT_PER_ACCOUNT
        );
        require(
            reserve.totalDepositAmount <= reserve.maxTotalDepositAmount, USDOErrors.EXCEED_THE_MAX_DEPOSIT_AMOUNT_TOTAL
        );
        emit Deposit(collateral, from, to, msg.sender, amount);
    }

    //    Pass parameter checking, excluding checking legality
    function _borrow(
        DataTypes.UserInfo storage user,
        bool isDepositToJOJO,
        address to,
        uint256 tAmount,
        address from
    ) internal {
        uint256 tRate = getTRate();
        //        tAmount % tRate ？ tAmount / tRate + 1 ： tAmount % tRate
        uint256 t0Amount = tAmount.decimalRemainder(tRate) ? tAmount.decimalDiv(tRate) : tAmount.decimalDiv(tRate) + 1;
        user.t0BorrowBalance += t0Amount;
        t0TotalBorrowAmount += t0Amount;
        if (isDepositToJOJO) {
            IERC20(USDO).approve(address(JOJODealer), tAmount);
            IDealer(JOJODealer).deposit(0, tAmount, to);
        } else {
            IERC20(USDO).safeTransfer(to, tAmount);
        }
        // Personal account hard cap
        require(
            user.t0BorrowBalance.decimalMul(tRate) <= maxPerAccountBorrowAmount,
            USDOErrors.EXCEED_THE_MAX_BORROW_AMOUNT_PER_ACCOUNT
        );
        // Global account hard cap
        require(
            t0TotalBorrowAmount.decimalMul(tRate) <= maxTotalBorrowAmount, USDOErrors.EXCEED_THE_MAX_BORROW_AMOUNT_TOTAL
        );
        emit Borrow(from, to, tAmount, isDepositToJOJO);
    }

    function _repay(
        DataTypes.UserInfo storage user,
        address payer,
        address to,
        uint256 amount,
        uint256 tRate
    ) internal returns (uint256) {
        require(amount != 0, USDOErrors.REPAY_AMOUNT_IS_ZERO);
        uint256 USDOBorrowed = user.t0BorrowBalance.decimalMul(tRate);
        uint256 tBorrowAmount;
        uint256 t0Amount;
        if (USDOBorrowed <= amount) {
            tBorrowAmount = USDOBorrowed;
            t0Amount = user.t0BorrowBalance;
        } else {
            tBorrowAmount = amount;
            t0Amount = amount.decimalDiv(tRate);
        }
        IERC20(USDO).safeTransferFrom(payer, address(this), tBorrowAmount);
        user.t0BorrowBalance -= t0Amount;
        t0TotalBorrowAmount -= t0Amount;
        emit Repay(payer, to, tBorrowAmount);
        return tBorrowAmount;
    }

    function _withdraw(uint256 amount, address collateral, address to, address from, bool isInternal) internal {
        DataTypes.ReserveInfo storage reserve = reserveInfo[collateral];
        DataTypes.UserInfo storage user = userInfo[from];
        require(amount != 0, USDOErrors.WITHDRAW_AMOUNT_IS_ZERO);
        require(amount <= user.depositBalance[collateral], USDOErrors.WITHDRAW_AMOUNT_IS_TOO_BIG);
        if (isInternal) {
            user.depositBalance[collateral] -= amount;
            DataTypes.UserInfo storage toAccount = userInfo[to];
            toAccount.depositBalance[collateral] += amount;
            require(
                toAccount.depositBalance[collateral] <= reserve.maxDepositAmountPerAccount,
                USDOErrors.EXCEED_THE_MAX_DEPOSIT_AMOUNT_PER_ACCOUNT
            );
        } else {
            reserve.totalDepositAmount -= amount;
            user.depositBalance[collateral] -= amount;
            IERC20(collateral).safeTransfer(to, amount);
            emit Withdraw(collateral, from, to, amount);
        }
        if (user.depositBalance[collateral] == 0) {
            _removeCollateral(user, collateral);
        }
    }

    /// @notice liquidate is divided into three steps,
    // 1. determine whether liquidatedTrader is safe
    // 2. calculate the collateral amount actually liquidated
    // 3. transfer the insurance fee
    function _calculateLiquidateAmount(
        address liquidated,
        address collateral,
        uint256 amount
    ) internal returns (DataTypes.LiquidateData memory liquidateData) {
        DataTypes.UserInfo storage liquidatedInfo = userInfo[liquidated];
        require(amount != 0, USDOErrors.LIQUIDATE_AMOUNT_IS_ZERO);
        require(amount <= liquidatedInfo.depositBalance[collateral], USDOErrors.LIQUIDATE_AMOUNT_IS_TOO_BIG);
        uint256 tRate = getTRate();
        require(_isStartLiquidation(liquidatedInfo, tRate), USDOErrors.ACCOUNT_IS_SAFE);
        DataTypes.ReserveInfo memory reserve = reserveInfo[collateral];
        uint256 price = IPriceChainLink(reserve.oracle).getAssetPrice();
        uint256 priceOff = price.decimalMul(DecimalMath.ONE - reserve.liquidationPriceOff);
        uint256 liquidateAmount = amount.decimalMul(priceOff).decimalMul(JOJOConstant.ONE - reserve.insuranceFeeRate);
        uint256 USDOBorrowed = liquidatedInfo.t0BorrowBalance.decimalMul(tRate);
        /*
        liquidateAmount <= USDOBorrowed
        liquidateAmount = amount * priceOff * (1-insuranceFee)
        actualUSDO = actualCollateral * priceOff
        insuranceFee = actualCollateral * priceOff * insuranceFeeRate
        */
        if (liquidateAmount <= USDOBorrowed) {
            liquidateData.actualCollateral = amount;
            liquidateData.insuranceFee = amount.decimalMul(priceOff).decimalMul(reserve.insuranceFeeRate);
            liquidateData.actualLiquidatedT0 = liquidateAmount.decimalDiv(tRate);
            liquidateData.actualLiquidated = liquidateAmount;
        } else {
            //            actualUSDO = actualCollateral * priceOff
            //            = USDOBorrowed * priceOff / priceOff * (1-insuranceFeeRate)
            //            = USDOBorrowed / (1-insuranceFeeRate)
            //            insuranceFee = actualUSDO * insuranceFeeRate
            //            = actualCollateral * priceOff * insuranceFeeRate
            //            = USDOBorrowed * insuranceFeeRate / (1- insuranceFeeRate)
            liquidateData.actualCollateral =
                USDOBorrowed.decimalDiv(priceOff).decimalDiv(JOJOConstant.ONE - reserve.insuranceFeeRate);
            liquidateData.insuranceFee = USDOBorrowed.decimalMul(reserve.insuranceFeeRate).decimalDiv(
                JOJOConstant.ONE - reserve.insuranceFeeRate
            );
            liquidateData.actualLiquidatedT0 = liquidatedInfo.t0BorrowBalance;
            liquidateData.actualLiquidated = USDOBorrowed;
        }

        liquidateData.liquidatedRemainUSDC = (amount - liquidateData.actualCollateral).decimalMul(price);
    }

    function _removeCollateral(DataTypes.UserInfo storage user, address collateral) internal {
        address[] storage collaterals = user.collateralList;
        for (uint256 i; i < collaterals.length; i = i + 1) {
            if (collaterals[i] == collateral) {
                collaterals[i] = collaterals[collaterals.length - 1];
                collaterals.pop();
                break;
            }
        }
    }

    /// @notice liquidate is trying to pay off all USDO debt instead of selling all collateral
    function _settleCollateralAndUSDO(
        DataTypes.UserInfo storage liquidatedInfo,
        address collateral,
        uint256 amount,
        uint256 tRate
    ) internal view returns (DataTypes.LiquidateData memory liquidateData) { }

    function _afterLiquidateOperation(
        bytes memory afterOperationParam,
        uint256 flashloanAmount,
        address collateral,
        address liquidated,
        DataTypes.LiquidateData memory liquidateData
    ) internal {
        (address flashloanAddress, bytes memory param) = abi.decode(afterOperationParam, (address, bytes));
        _withdraw(flashloanAmount, collateral, flashloanAddress, liquidated, false);
        param = abi.encode(liquidateData, param);
        IFlashLoanReceive(flashloanAddress).JOJOFlashLoan(collateral, flashloanAmount, liquidated, param);
    }

    /// @notice handle the bad debt
    /// @param liquidatedTrader need to be liquidated
    function _handleBadDebt(address liquidatedTrader) internal {
        DataTypes.UserInfo storage liquidatedTraderInfo = userInfo[liquidatedTrader];
        uint256 tRate = getTRate();
        if (liquidatedTraderInfo.collateralList.length == 0 && _isStartLiquidation(liquidatedTraderInfo, tRate)) {
            DataTypes.UserInfo storage insuranceInfo = userInfo[insurance];
            uint256 borrowUSDOT0 = liquidatedTraderInfo.t0BorrowBalance;
            insuranceInfo.t0BorrowBalance += borrowUSDOT0;
            liquidatedTraderInfo.t0BorrowBalance = 0;
            emit HandleBadDebt(liquidatedTrader, borrowUSDOT0);
        }
    }
}