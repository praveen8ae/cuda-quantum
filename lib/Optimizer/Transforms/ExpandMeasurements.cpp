/*************************************************************** -*- C++ -*- ***
 * Copyright (c) 2022 - 2023 NVIDIA Corporation & Affiliates.                  *
 * All rights reserved.                                                        *
 *                                                                             *
 * This source code and the accompanying materials are made available under    *
 * the terms of the Apache License 2.0 which accompanies this distribution.    *
 *******************************************************************************/

#include "PassDetails.h"
#include "cudaq/Optimizer/Builder/Factory.h"
#include "cudaq/Optimizer/Dialect/CC/CCOps.h"
#include "cudaq/Optimizer/Dialect/Quake/QuakeOps.h"
#include "cudaq/Optimizer/Transforms/Passes.h"
#include "cudaq/Todo.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/Transforms/Passes.h"

using namespace mlir;

// Only an individual qubit measurement returns a bool.
template <typename A>
bool usesIndividualQubit(A x) {
  return x.getType() == IntegerType::get(x.getContext(), 1);
}

// Generalized pattern for expanding a multiple qubit measurement (whether it is
// mx, my, or mz) to a series of individual measurements.
template <typename A>
class ExpandRewritePattern : public OpRewritePattern<A> {
public:
  using OpRewritePattern<A>::OpRewritePattern;

  LogicalResult matchAndRewrite(A measureOp,
                                PatternRewriter &rewriter) const override {
    auto loc = measureOp.getLoc();
    // 1. Determine the total number of qubits we need to measure. This
    // determines the size of the buffer of bools to create to store the results
    // in.
    unsigned numQubits = 0u;
    for (auto v : measureOp.getTargets())
      if (v.getType().template isa<quake::QRefType>())
        ++numQubits;
    Value totalToRead =
        rewriter.template create<arith::ConstantIndexOp>(loc, numQubits);
    auto idxTy = rewriter.getIndexType();
    for (auto v : measureOp.getTargets())
      if (v.getType().template isa<quake::QVecType>()) {
        Value vecSz =
            rewriter.template create<quake::QVecSizeOp>(loc, idxTy, v);
        totalToRead =
            rewriter.template create<arith::AddIOp>(loc, totalToRead, vecSz);
      }
    auto i1Ty = rewriter.getI1Type();
    auto i1PtrTy = cudaq::opt::factory::getPointerType(i1Ty);

    // 2. Create the buffer.
    auto i64Ty = rewriter.getI64Type();
    Value buffLen =
        rewriter.template create<arith::IndexCastOp>(loc, i64Ty, totalToRead);
    Value buff =
        rewriter.template create<LLVM::AllocaOp>(loc, i1PtrTy, buffLen);

    // 3. Measure each individual qubit and insert the result, in order, into
    // the buffer. For registers/vectors, loop over the entire set of qubits.
    Value buffOff = rewriter.template create<arith::ConstantIndexOp>(loc, 0);
    Value one = rewriter.template create<arith::ConstantIndexOp>(loc, 1);
    for (auto v : measureOp.getTargets()) {
      if (v.getType().template isa<quake::QRefType>()) {
        auto bit = rewriter.template create<A>(loc, i1Ty, v);
        Value offCast =
            rewriter.template create<arith::IndexCastOp>(loc, i64Ty, buffOff);
        auto addr =
            rewriter.template create<LLVM::GEPOp>(loc, i1PtrTy, buff, offCast);
        rewriter.template create<LLVM::StoreOp>(loc, bit, addr);
        buffOff = rewriter.template create<arith::AddIOp>(loc, buffOff, one);
      } else {
        Value vecSz =
            rewriter.template create<quake::QVecSizeOp>(loc, idxTy, v);
        cudaq::opt::factory::createCountedLoop(
            rewriter, loc, vecSz,
            [&](OpBuilder &builder, Location loc, Region &, Block &block) {
              Value iv = block.getArgument(0);
              Value qv = builder.template create<quake::QExtractOp>(loc, v, iv);
              auto bit = builder.template create<A>(loc, i1Ty, qv);
              auto offset =
                  builder.template create<arith::AddIOp>(loc, iv, buffOff);
              Value offCast = builder.template create<arith::IndexCastOp>(
                  loc, i64Ty, offset);
              auto addr = builder.template create<LLVM::GEPOp>(loc, i1PtrTy,
                                                               buff, offCast);
              builder.template create<LLVM::StoreOp>(loc, bit, addr);
            });
        buffOff = rewriter.template create<arith::AddIOp>(loc, buffOff, vecSz);
      }
    }

    // 4. Use the buffer as an initialization expression and create the
    // std::vec<bool> value.
    auto stdvecTy = cudaq::cc::StdvecType::get(rewriter.getContext(), i1Ty);
    rewriter.template replaceOpWithNewOp<cudaq::cc::StdvecInitOp>(
        measureOp, stdvecTy, buff, buffLen);
    return success();
  }
};

namespace {
using MxRewrite = ExpandRewritePattern<quake::MxOp>;
using MyRewrite = ExpandRewritePattern<quake::MyOp>;
using MzRewrite = ExpandRewritePattern<quake::MzOp>;

class ExpandMeasurementsPass
    : public cudaq::opt::ExpandMeasurementsBase<ExpandMeasurementsPass> {
public:
  void runOnOperation() override {
    auto *op = getOperation();
    auto *ctx = &getContext();
    RewritePatternSet patterns(ctx);
    patterns.insert<MxRewrite, MyRewrite, MzRewrite>(ctx);
    ConversionTarget target(*ctx);
    target.addLegalDialect<quake::QuakeDialect, cudaq::cc::CCDialect,
                           arith::ArithDialect, LLVM::LLVMDialect>();
    target.addDynamicallyLegalOp<quake::MxOp>(
        [](quake::MxOp x) { return usesIndividualQubit(x); });
    target.addDynamicallyLegalOp<quake::MyOp>(
        [](quake::MyOp x) { return usesIndividualQubit(x); });
    target.addDynamicallyLegalOp<quake::MzOp>(
        [](quake::MzOp x) { return usesIndividualQubit(x); });
    if (failed(applyPartialConversion(op, target, std::move(patterns)))) {
      emitError(op->getLoc(), "error expanding measurements\n");
      signalPassFailure();
    }
  }
};
} // namespace

std::unique_ptr<mlir::Pass> cudaq::opt::createExpandMeasurementsPass() {
  return std::make_unique<ExpandMeasurementsPass>();
}
