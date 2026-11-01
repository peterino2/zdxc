//! What SPIR-V instructions and enumerants need (the first capability /
//! extension the grammar lists), for inline SPIR-V. Generated from
//! SPIRV-Headers' spirv.core.grammar.json in the DXC tree
//! (external/SPIRV-Headers).

const std = @import("std");

const ops = [_][2]u32{
    .{ 24, 0 }, // OpTypeMatrix
    .{ 29, 1 }, // OpTypeRuntimeArray
    .{ 31, 6 }, // OpTypeOpaque
    .{ 34, 6 }, // OpTypeEvent
    .{ 35, 19 }, // OpTypeDeviceEvent
    .{ 36, 17 }, // OpTypeReserveId
    .{ 37, 19 }, // OpTypeQueue
    .{ 38, 17 }, // OpTypePipe
    .{ 39, 4 }, // OpTypeForwardPointer
    .{ 45, 20 }, // OpConstantSampler
    .{ 64, 4 }, // OpCopyMemorySized
    .{ 67, 4 }, // OpPtrAccessChain
    .{ 68, 1 }, // OpArrayLength
    .{ 69, 6 }, // OpGenericPtrMemSemantics
    .{ 70, 4 }, // OpInBoundsPtrAccessChain
    .{ 84, 0 }, // OpTranspose
    .{ 87, 1 }, // OpImageSampleImplicitLod
    .{ 89, 1 }, // OpImageSampleDrefImplicitLod
    .{ 90, 1 }, // OpImageSampleDrefExplicitLod
    .{ 91, 1 }, // OpImageSampleProjImplicitLod
    .{ 92, 1 }, // OpImageSampleProjExplicitLod
    .{ 93, 1 }, // OpImageSampleProjDrefImplicitLod
    .{ 94, 1 }, // OpImageSampleProjDrefExplicitLod
    .{ 96, 1 }, // OpImageGather
    .{ 97, 1 }, // OpImageDrefGather
    .{ 101, 6 }, // OpImageQueryFormat
    .{ 102, 6 }, // OpImageQueryOrder
    .{ 103, 6 }, // OpImageQuerySizeLod
    .{ 104, 6 }, // OpImageQuerySize
    .{ 105, 50 }, // OpImageQueryLod
    .{ 106, 6 }, // OpImageQueryLevels
    .{ 107, 6 }, // OpImageQuerySamples
    .{ 116, 1 }, // OpQuantizeToF16
    .{ 117, 4 }, // OpConvertPtrToU
    .{ 118, 6 }, // OpSatConvertSToU
    .{ 119, 6 }, // OpSatConvertUToS
    .{ 120, 4 }, // OpConvertUToPtr
    .{ 121, 6 }, // OpPtrCastToGeneric
    .{ 122, 6 }, // OpGenericCastToPtr
    .{ 123, 6 }, // OpGenericCastToPtrExplicit
    .{ 143, 0 }, // OpMatrixTimesScalar
    .{ 144, 0 }, // OpVectorTimesMatrix
    .{ 145, 0 }, // OpMatrixTimesVector
    .{ 146, 0 }, // OpMatrixTimesMatrix
    .{ 147, 0 }, // OpOuterProduct
    .{ 158, 6 }, // OpIsFinite
    .{ 159, 6 }, // OpIsNormal
    .{ 160, 6 }, // OpSignBitSet
    .{ 161, 6 }, // OpLessOrGreater
    .{ 162, 6 }, // OpOrdered
    .{ 163, 6 }, // OpUnordered
    .{ 201, 1 }, // OpBitFieldInsert
    .{ 202, 1 }, // OpBitFieldSExtract
    .{ 203, 1 }, // OpBitFieldUExtract
    .{ 204, 1 }, // OpBitReverse
    .{ 207, 1 }, // OpDPdx
    .{ 208, 1 }, // OpDPdy
    .{ 209, 1 }, // OpFwidth
    .{ 210, 51 }, // OpDPdxFine
    .{ 211, 51 }, // OpDPdyFine
    .{ 212, 51 }, // OpFwidthFine
    .{ 213, 51 }, // OpDPdxCoarse
    .{ 214, 51 }, // OpDPdyCoarse
    .{ 215, 51 }, // OpFwidthCoarse
    .{ 218, 2 }, // OpEmitVertex
    .{ 219, 2 }, // OpEndPrimitive
    .{ 220, 54 }, // OpEmitStreamVertex
    .{ 221, 54 }, // OpEndStreamPrimitive
    .{ 231, 6 }, // OpAtomicCompareExchangeWeak
    .{ 252, 1 }, // OpKill
    .{ 256, 6 }, // OpLifetimeStart
    .{ 257, 6 }, // OpLifetimeStop
    .{ 259, 6 }, // OpGroupAsyncCopy
    .{ 260, 6 }, // OpGroupWaitEvents
    .{ 261, 18 }, // OpGroupAll
    .{ 262, 18 }, // OpGroupAny
    .{ 263, 18 }, // OpGroupBroadcast
    .{ 264, 18 }, // OpGroupIAdd
    .{ 265, 18 }, // OpGroupFAdd
    .{ 266, 18 }, // OpGroupFMin
    .{ 267, 18 }, // OpGroupUMin
    .{ 268, 18 }, // OpGroupSMin
    .{ 269, 18 }, // OpGroupFMax
    .{ 270, 18 }, // OpGroupUMax
    .{ 271, 18 }, // OpGroupSMax
    .{ 274, 17 }, // OpReadPipe
    .{ 275, 17 }, // OpWritePipe
    .{ 276, 17 }, // OpReservedReadPipe
    .{ 277, 17 }, // OpReservedWritePipe
    .{ 278, 17 }, // OpReserveReadPipePackets
    .{ 279, 17 }, // OpReserveWritePipePackets
    .{ 280, 17 }, // OpCommitReadPipe
    .{ 281, 17 }, // OpCommitWritePipe
    .{ 282, 17 }, // OpIsValidReserveId
    .{ 283, 17 }, // OpGetNumPipePackets
    .{ 284, 17 }, // OpGetMaxPipePackets
    .{ 285, 17 }, // OpGroupReserveReadPipePackets
    .{ 286, 17 }, // OpGroupReserveWritePipePackets
    .{ 287, 17 }, // OpGroupCommitReadPipe
    .{ 288, 17 }, // OpGroupCommitWritePipe
    .{ 291, 19 }, // OpEnqueueMarker
    .{ 292, 19 }, // OpEnqueueKernel
    .{ 293, 19 }, // OpGetKernelNDrangeSubGroupCount
    .{ 294, 19 }, // OpGetKernelNDrangeMaxSubGroupSize
    .{ 295, 19 }, // OpGetKernelWorkGroupSize
    .{ 296, 19 }, // OpGetKernelPreferredWorkGroupSizeMultiple
    .{ 297, 19 }, // OpRetainEvent
    .{ 298, 19 }, // OpReleaseEvent
    .{ 299, 19 }, // OpCreateUserEvent
    .{ 300, 19 }, // OpIsValidEvent
    .{ 301, 19 }, // OpSetUserEventStatus
    .{ 302, 19 }, // OpCaptureEventProfilingInfo
    .{ 303, 19 }, // OpGetDefaultQueue
    .{ 304, 19 }, // OpBuildNDRange
    .{ 305, 41 }, // OpImageSparseSampleImplicitLod
    .{ 306, 41 }, // OpImageSparseSampleExplicitLod
    .{ 307, 41 }, // OpImageSparseSampleDrefImplicitLod
    .{ 308, 41 }, // OpImageSparseSampleDrefExplicitLod
    .{ 309, 41 }, // OpImageSparseSampleProjImplicitLod
    .{ 310, 41 }, // OpImageSparseSampleProjExplicitLod
    .{ 311, 41 }, // OpImageSparseSampleProjDrefImplicitLod
    .{ 312, 41 }, // OpImageSparseSampleProjDrefExplicitLod
    .{ 313, 41 }, // OpImageSparseFetch
    .{ 314, 41 }, // OpImageSparseGather
    .{ 315, 41 }, // OpImageSparseDrefGather
    .{ 316, 41 }, // OpImageSparseTexelsResident
    .{ 318, 6 }, // OpAtomicFlagTestAndSet
    .{ 319, 6 }, // OpAtomicFlagClear
    .{ 320, 41 }, // OpImageSparseRead
    .{ 321, 4 }, // OpSizeOf
    .{ 322, 60 }, // OpTypePipeStorage
    .{ 323, 60 }, // OpConstantPipeStorage
    .{ 324, 60 }, // OpCreatePipeFromPipeStorage
    .{ 325, 58 }, // OpGetKernelLocalSizeForSubgroupCount
    .{ 326, 58 }, // OpGetKernelMaxNumSubgroups
    .{ 327, 59 }, // OpTypeNamedBarrier
    .{ 328, 59 }, // OpNamedBarrierInitialize
    .{ 329, 59 }, // OpMemoryNamedBarrier
    .{ 333, 61 }, // OpGroupNonUniformElect
    .{ 334, 62 }, // OpGroupNonUniformAll
    .{ 335, 62 }, // OpGroupNonUniformAny
    .{ 336, 62 }, // OpGroupNonUniformAllEqual
    .{ 337, 64 }, // OpGroupNonUniformBroadcast
    .{ 338, 64 }, // OpGroupNonUniformBroadcastFirst
    .{ 339, 64 }, // OpGroupNonUniformBallot
    .{ 340, 64 }, // OpGroupNonUniformInverseBallot
    .{ 341, 64 }, // OpGroupNonUniformBallotBitExtract
    .{ 342, 64 }, // OpGroupNonUniformBallotBitCount
    .{ 343, 64 }, // OpGroupNonUniformBallotFindLSB
    .{ 344, 64 }, // OpGroupNonUniformBallotFindMSB
    .{ 345, 65 }, // OpGroupNonUniformShuffle
    .{ 346, 65 }, // OpGroupNonUniformShuffleXor
    .{ 347, 66 }, // OpGroupNonUniformShuffleUp
    .{ 348, 66 }, // OpGroupNonUniformShuffleDown
    .{ 349, 63 }, // OpGroupNonUniformIAdd
    .{ 350, 63 }, // OpGroupNonUniformFAdd
    .{ 351, 63 }, // OpGroupNonUniformIMul
    .{ 352, 63 }, // OpGroupNonUniformFMul
    .{ 353, 63 }, // OpGroupNonUniformSMin
    .{ 354, 63 }, // OpGroupNonUniformUMin
    .{ 355, 63 }, // OpGroupNonUniformFMin
    .{ 356, 63 }, // OpGroupNonUniformSMax
    .{ 357, 63 }, // OpGroupNonUniformUMax
    .{ 358, 63 }, // OpGroupNonUniformFMax
    .{ 359, 63 }, // OpGroupNonUniformBitwiseAnd
    .{ 360, 63 }, // OpGroupNonUniformBitwiseOr
    .{ 361, 63 }, // OpGroupNonUniformBitwiseXor
    .{ 362, 63 }, // OpGroupNonUniformLogicalAnd
    .{ 363, 63 }, // OpGroupNonUniformLogicalOr
    .{ 364, 63 }, // OpGroupNonUniformLogicalXor
    .{ 365, 68 }, // OpGroupNonUniformQuadBroadcast
    .{ 366, 68 }, // OpGroupNonUniformQuadSwap
    .{ 403, 4 }, // OpPtrDiff
    .{ 4160, 4166 }, // OpColorAttachmentReadEXT
    .{ 4161, 4167 }, // OpDepthAttachmentReadEXT
    .{ 4162, 4168 }, // OpStencilAttachmentReadEXT
    .{ 4163, 4174 }, // OpTypeTensorARM
    .{ 4164, 4174 }, // OpTensorReadARM
    .{ 4165, 4174 }, // OpTensorWriteARM
    .{ 4166, 4174 }, // OpTensorQuerySizeARM
    .{ 4181, 4191 }, // OpGraphConstantARM
    .{ 4182, 4191 }, // OpGraphEntryPointARM
    .{ 4183, 4191 }, // OpGraphARM
    .{ 4184, 4191 }, // OpGraphInputARM
    .{ 4185, 4191 }, // OpGraphSetOutputARM
    .{ 4186, 4191 }, // OpGraphEndARM
    .{ 4190, 4191 }, // OpTypeGraphARM
    .{ 4195, 4232 }, // OpBitcastExtractEXT
    .{ 4416, 1 }, // OpTerminateInvocation
    .{ 4417, 4473 }, // OpTypeUntypedPointerKHR
    .{ 4418, 4473 }, // OpUntypedVariableKHR
    .{ 4419, 4473 }, // OpUntypedAccessChainKHR
    .{ 4420, 4473 }, // OpUntypedInBoundsAccessChainKHR
    .{ 4421, 4423 }, // OpSubgroupBallotKHR
    .{ 4422, 4423 }, // OpSubgroupFirstInvocationKHR
    .{ 4423, 4473 }, // OpUntypedPtrAccessChainKHR
    .{ 4424, 4473 }, // OpUntypedInBoundsPtrAccessChainKHR
    .{ 4425, 4473 }, // OpUntypedArrayLengthKHR
    .{ 4426, 4473 }, // OpUntypedPrefetchKHR
    .{ 4427, 6030 }, // OpFmaKHR
    .{ 4428, 4431 }, // OpSubgroupAllKHR
    .{ 4429, 4431 }, // OpSubgroupAnyKHR
    .{ 4430, 4431 }, // OpSubgroupAllEqualKHR
    .{ 4431, 6026 }, // OpGroupNonUniformRotateKHR
    .{ 4432, 4423 }, // OpSubgroupReadInvocationKHR
    .{ 4434, 4473 }, // OpUntypedGroupAsyncCopyKHR
    .{ 4445, 4479 }, // OpTraceRayKHR
    .{ 4446, 4479 }, // OpExecuteCallableKHR
    .{ 4447, 4479 }, // OpConvertUToAccelerationStructureKHR
    .{ 4448, 4479 }, // OpIgnoreIntersectionKHR
    .{ 4449, 4479 }, // OpTerminateRayKHR
    .{ 4450, 6019 }, // OpSDot
    .{ 4451, 6019 }, // OpUDot
    .{ 4452, 6019 }, // OpSUDot
    .{ 4453, 6019 }, // OpSDotAccSat
    .{ 4454, 6019 }, // OpUDotAccSat
    .{ 4455, 6019 }, // OpSUDotAccSat
    .{ 4456, 6022 }, // OpTypeCooperativeMatrixKHR
    .{ 4457, 6022 }, // OpCooperativeMatrixLoadKHR
    .{ 4458, 6022 }, // OpCooperativeMatrixStoreKHR
    .{ 4459, 6022 }, // OpCooperativeMatrixMulAddKHR
    .{ 4460, 6022 }, // OpCooperativeMatrixLengthKHR
    .{ 4461, 6024 }, // OpConstantCompositeReplicateEXT
    .{ 4462, 6024 }, // OpSpecConstantCompositeReplicateEXT
    .{ 4463, 6024 }, // OpCompositeConstructReplicateEXT
    .{ 4472, 4472 }, // OpTypeRayQueryKHR
    .{ 4473, 4472 }, // OpRayQueryInitializeKHR
    .{ 4474, 4472 }, // OpRayQueryTerminateKHR
    .{ 4475, 4472 }, // OpRayQueryGenerateIntersectionKHR
    .{ 4476, 4472 }, // OpRayQueryConfirmIntersectionKHR
    .{ 4477, 4472 }, // OpRayQueryProceedKHR
    .{ 4479, 4472 }, // OpRayQueryGetIntersectionTypeKHR
    .{ 4480, 4484 }, // OpImageSampleWeightedQCOM
    .{ 4481, 4485 }, // OpImageBoxFilterQCOM
    .{ 4482, 4486 }, // OpImageBlockMatchSSDQCOM
    .{ 4483, 4486 }, // OpImageBlockMatchSADQCOM
    .{ 4497, 4496 }, // OpBitCastArrayQCOM
    .{ 4500, 4498 }, // OpImageBlockMatchWindowSSDQCOM
    .{ 4501, 4498 }, // OpImageBlockMatchWindowSADQCOM
    .{ 4502, 4498 }, // OpImageBlockMatchGatherSSDQCOM
    .{ 4503, 4498 }, // OpImageBlockMatchGatherSADQCOM
    .{ 4540, 4496 }, // OpCompositeConstructCoopMatQCOM
    .{ 4541, 4496 }, // OpCompositeExtractCoopMatQCOM
    .{ 4542, 4496 }, // OpExtractSubArrayQCOM
    .{ 4545, 4543 }, // OpImageGatherQCOM
    .{ 5000, 18 }, // OpGroupIAddNonUniformAMD
    .{ 5001, 18 }, // OpGroupFAddNonUniformAMD
    .{ 5002, 18 }, // OpGroupFMinNonUniformAMD
    .{ 5003, 18 }, // OpGroupUMinNonUniformAMD
    .{ 5004, 18 }, // OpGroupSMinNonUniformAMD
    .{ 5005, 18 }, // OpGroupFMaxNonUniformAMD
    .{ 5006, 18 }, // OpGroupUMaxNonUniformAMD
    .{ 5007, 18 }, // OpGroupSMaxNonUniformAMD
    .{ 5011, 5010 }, // OpFragmentMaskFetchAMD
    .{ 5012, 5010 }, // OpFragmentFetchAMD
    .{ 5056, 5055 }, // OpReadClockKHR
    .{ 5074, 5067 }, // OpAllocateNodePayloadsAMDX
    .{ 5075, 5067 }, // OpEnqueueNodePayloadsAMDX
    .{ 5076, 5067 }, // OpTypeNodePayloadArrayAMDX
    .{ 5078, 5067 }, // OpFinishWritingNodePayloadAMDX
    .{ 5090, 5067 }, // OpNodePayloadArrayLengthAMDX
    .{ 5101, 5067 }, // OpIsNodePayloadValidAMDX
    .{ 5103, 5067 }, // OpConstantStringAMDX
    .{ 5104, 5067 }, // OpSpecConstantStringAMDX
    .{ 5110, 5087 }, // OpGroupNonUniformQuadAllKHR
    .{ 5111, 5087 }, // OpGroupNonUniformQuadAnyKHR
    .{ 5115, 5128 }, // OpTypeBufferEXT
    .{ 5119, 5128 }, // OpBufferPointerEXT
    .{ 5121, 5120 }, // OpAbortKHR
    .{ 5126, 5128 }, // OpUntypedImageTexelPointerEXT
    .{ 5127, 5128 }, // OpMemberDecorateIdEXT
    .{ 5129, 5128 }, // OpConstantSizeOfEXT
    .{ 5147, 5146 }, // OpConstantDataKHR
    .{ 5148, 5146 }, // OpSpecConstantDataKHR
    .{ 5158, 5156 }, // OpPoisonKHR
    .{ 5159, 5156 }, // OpFreezeKHR
    .{ 5249, 5383 }, // OpHitObjectRecordHitMotionNV
    .{ 5250, 5383 }, // OpHitObjectRecordHitWithIndexMotionNV
    .{ 5251, 5383 }, // OpHitObjectRecordMissMotionNV
    .{ 5252, 5383 }, // OpHitObjectGetWorldToObjectNV
    .{ 5253, 5383 }, // OpHitObjectGetObjectToWorldNV
    .{ 5254, 5383 }, // OpHitObjectGetObjectRayDirectionNV
    .{ 5255, 5383 }, // OpHitObjectGetObjectRayOriginNV
    .{ 5256, 5383 }, // OpHitObjectTraceRayMotionNV
    .{ 5257, 5383 }, // OpHitObjectGetShaderRecordBufferHandleNV
    .{ 5258, 5383 }, // OpHitObjectGetShaderBindingTableRecordIndexNV
    .{ 5259, 5383 }, // OpHitObjectRecordEmptyNV
    .{ 5260, 5383 }, // OpHitObjectTraceRayNV
    .{ 5261, 5383 }, // OpHitObjectRecordHitNV
    .{ 5262, 5383 }, // OpHitObjectRecordHitWithIndexNV
    .{ 5263, 5383 }, // OpHitObjectRecordMissNV
    .{ 5264, 5383 }, // OpHitObjectExecuteShaderNV
    .{ 5265, 5383 }, // OpHitObjectGetCurrentTimeNV
    .{ 5266, 5383 }, // OpHitObjectGetAttributesNV
    .{ 5267, 5383 }, // OpHitObjectGetHitKindNV
    .{ 5268, 5383 }, // OpHitObjectGetPrimitiveIndexNV
    .{ 5269, 5383 }, // OpHitObjectGetGeometryIndexNV
    .{ 5270, 5383 }, // OpHitObjectGetInstanceIdNV
    .{ 5271, 5383 }, // OpHitObjectGetInstanceCustomIndexNV
    .{ 5272, 5383 }, // OpHitObjectGetWorldRayDirectionNV
    .{ 5273, 5383 }, // OpHitObjectGetWorldRayOriginNV
    .{ 5274, 5383 }, // OpHitObjectGetRayTMaxNV
    .{ 5275, 5383 }, // OpHitObjectGetRayTMinNV
    .{ 5276, 5383 }, // OpHitObjectIsEmptyNV
    .{ 5277, 5383 }, // OpHitObjectIsHitNV
    .{ 5278, 5383 }, // OpHitObjectIsMissNV
    .{ 5279, 5383 }, // OpReorderThreadWithHitObjectNV
    .{ 5280, 5383 }, // OpReorderThreadWithHintNV
    .{ 5281, 5383 }, // OpTypeHitObjectNV
    .{ 5283, 5282 }, // OpImageSampleFootprintNV
    .{ 5288, 5394 }, // OpTypeVectorIdEXT
    .{ 5289, 5394 }, // OpCooperativeVectorMatrixMulNV
    .{ 5290, 5435 }, // OpCooperativeVectorOuterProductAccumulateNV
    .{ 5291, 5435 }, // OpCooperativeVectorReduceSumAccumulateNV
    .{ 5292, 5394 }, // OpCooperativeVectorMatrixMulAddNV
    .{ 5293, 5431 }, // OpCooperativeMatrixConvertNV
    .{ 5294, 5283 }, // OpEmitMeshTasksEXT
    .{ 5295, 5283 }, // OpSetMeshOutputsEXT
    .{ 5296, 5297 }, // OpGroupNonUniformPartitionEXT
    .{ 5299, 5266 }, // OpWritePackedPrimitiveIndices4x8NV
    .{ 5300, 5380 }, // OpFetchMicroTriangleVertexPositionNV
    .{ 5301, 5380 }, // OpFetchMicroTriangleVertexBarycentricNV
    .{ 5302, 5394 }, // OpCooperativeVectorLoadNV
    .{ 5303, 5394 }, // OpCooperativeVectorStoreNV
    .{ 5304, 5388 }, // OpHitObjectRecordFromQueryEXT
    .{ 5305, 5388 }, // OpHitObjectRecordMissEXT
    .{ 5306, 5388 }, // OpHitObjectRecordMissMotionEXT
    .{ 5307, 5388 }, // OpHitObjectGetIntersectionTriangleVertexPositionsEXT
    .{ 5308, 5388 }, // OpHitObjectGetRayFlagsEXT
    .{ 5309, 5388 }, // OpHitObjectSetShaderBindingTableRecordIndexEXT
    .{ 5310, 5388 }, // OpHitObjectReorderExecuteShaderEXT
    .{ 5311, 5388 }, // OpHitObjectTraceReorderExecuteEXT
    .{ 5312, 5388 }, // OpHitObjectTraceMotionReorderExecuteEXT
    .{ 5313, 5388 }, // OpTypeHitObjectEXT
    .{ 5314, 5388 }, // OpReorderThreadWithHintEXT
    .{ 5315, 5388 }, // OpReorderThreadWithHitObjectEXT
    .{ 5316, 5388 }, // OpHitObjectTraceRayEXT
    .{ 5317, 5388 }, // OpHitObjectTraceRayMotionEXT
    .{ 5318, 5388 }, // OpHitObjectRecordEmptyEXT
    .{ 5319, 5388 }, // OpHitObjectExecuteShaderEXT
    .{ 5320, 5388 }, // OpHitObjectGetCurrentTimeEXT
    .{ 5321, 5388 }, // OpHitObjectGetAttributesEXT
    .{ 5322, 5388 }, // OpHitObjectGetHitKindEXT
    .{ 5323, 5388 }, // OpHitObjectGetPrimitiveIndexEXT
    .{ 5324, 5388 }, // OpHitObjectGetGeometryIndexEXT
    .{ 5325, 5388 }, // OpHitObjectGetInstanceIdEXT
    .{ 5326, 5388 }, // OpHitObjectGetInstanceCustomIndexEXT
    .{ 5327, 5388 }, // OpHitObjectGetObjectRayOriginEXT
    .{ 5328, 5388 }, // OpHitObjectGetObjectRayDirectionEXT
    .{ 5329, 5388 }, // OpHitObjectGetWorldRayDirectionEXT
    .{ 5330, 5388 }, // OpHitObjectGetWorldRayOriginEXT
    .{ 5331, 5388 }, // OpHitObjectGetObjectToWorldEXT
    .{ 5332, 5388 }, // OpHitObjectGetWorldToObjectEXT
    .{ 5333, 5388 }, // OpHitObjectGetRayTMaxEXT
    .{ 5334, 5340 }, // OpReportIntersectionKHR
    .{ 5335, 5340 }, // OpIgnoreIntersectionNV
    .{ 5336, 5340 }, // OpTerminateRayNV
    .{ 5337, 5340 }, // OpTraceNV
    .{ 5338, 5341 }, // OpTraceMotionNV
    .{ 5339, 5341 }, // OpTraceRayMotionNV
    .{ 5340, 5391 }, // OpRayQueryGetIntersectionTriangleVertexPositionsKHR
    .{ 5341, 5340 }, // OpTypeAccelerationStructureKHR
    .{ 5344, 5340 }, // OpExecuteCallableNV
    .{ 5345, 5437 }, // OpRayQueryGetIntersectionClusterIdNV
    .{ 5346, 5437 }, // OpHitObjectGetClusterIdNV
    .{ 5347, 5388 }, // OpHitObjectGetRayTMinEXT
    .{ 5348, 5388 }, // OpHitObjectGetShaderBindingTableRecordIndexEXT
    .{ 5349, 5388 }, // OpHitObjectGetShaderRecordBufferHandleEXT
    .{ 5350, 5388 }, // OpHitObjectIsEmptyEXT
    .{ 5351, 5388 }, // OpHitObjectIsHitEXT
    .{ 5352, 5388 }, // OpHitObjectIsMissEXT
    .{ 5358, 5357 }, // OpTypeCooperativeMatrixNV
    .{ 5359, 5357 }, // OpCooperativeMatrixLoadNV
    .{ 5360, 5357 }, // OpCooperativeMatrixStoreNV
    .{ 5361, 5357 }, // OpCooperativeMatrixMulAddNV
    .{ 5362, 5357 }, // OpCooperativeMatrixLengthNV
    .{ 5364, 5363 }, // OpBeginInvocationInterlockEXT
    .{ 5365, 5363 }, // OpEndInvocationInterlockEXT
    .{ 5366, 5430 }, // OpCooperativeMatrixReduceNV
    .{ 5367, 5433 }, // OpCooperativeMatrixLoadTensorNV
    .{ 5368, 5433 }, // OpCooperativeMatrixStoreTensorNV
    .{ 5369, 5432 }, // OpCooperativeMatrixPerElementOpNV
    .{ 5370, 5439 }, // OpTypeTensorLayoutNV
    .{ 5371, 5439 }, // OpTypeTensorViewNV
    .{ 5372, 5439 }, // OpCreateTensorLayoutNV
    .{ 5373, 5439 }, // OpTensorLayoutSetDimensionNV
    .{ 5374, 5439 }, // OpTensorLayoutSetStrideNV
    .{ 5375, 5439 }, // OpTensorLayoutSliceNV
    .{ 5376, 5439 }, // OpTensorLayoutSetClampValueNV
    .{ 5377, 5439 }, // OpCreateTensorViewNV
    .{ 5378, 5439 }, // OpTensorViewSetDimensionNV
    .{ 5379, 5439 }, // OpTensorViewSetStrideNV
    .{ 5380, 5379 }, // OpDemoteToHelperInvocation
    .{ 5381, 5379 }, // OpIsHelperInvocationEXT
    .{ 5382, 5439 }, // OpTensorViewSetClipNV
    .{ 5384, 5439 }, // OpTensorLayoutSetBlockSizeNV
    .{ 5390, 5431 }, // OpCooperativeMatrixTransposeNV
    .{ 5391, 5390 }, // OpConvertUToImageNV
    .{ 5392, 5390 }, // OpConvertUToSamplerNV
    .{ 5393, 5390 }, // OpConvertImageToUNV
    .{ 5394, 5390 }, // OpConvertSamplerToUNV
    .{ 5395, 5390 }, // OpConvertUToSampledImageNV
    .{ 5396, 5390 }, // OpConvertSampledImageToUNV
    .{ 5397, 5390 }, // OpSamplerImageAddressingModeNV
    .{ 5398, 5414 }, // OpRawAccessChainNV
    .{ 5427, 5418 }, // OpRayQueryGetIntersectionSpherePositionNV
    .{ 5428, 5418 }, // OpRayQueryGetIntersectionSphereRadiusNV
    .{ 5429, 5419 }, // OpRayQueryGetIntersectionLSSPositionsNV
    .{ 5430, 5419 }, // OpRayQueryGetIntersectionLSSRadiiNV
    .{ 5431, 5419 }, // OpRayQueryGetIntersectionLSSHitValueNV
    .{ 5432, 5418 }, // OpHitObjectGetSpherePositionNV
    .{ 5433, 5418 }, // OpHitObjectGetSphereRadiusNV
    .{ 5434, 5419 }, // OpHitObjectGetLSSPositionsNV
    .{ 5435, 5419 }, // OpHitObjectGetLSSRadiiNV
    .{ 5436, 5418 }, // OpHitObjectIsSphereHitNV
    .{ 5437, 5419 }, // OpHitObjectIsLSSHitNV
    .{ 5438, 5418 }, // OpRayQueryIsSphereHitNV
    .{ 5439, 5419 }, // OpRayQueryIsLSSHitNV
    .{ 5571, 5568 }, // OpSubgroupShuffleINTEL
    .{ 5572, 5568 }, // OpSubgroupShuffleDownINTEL
    .{ 5573, 5568 }, // OpSubgroupShuffleUpINTEL
    .{ 5574, 5568 }, // OpSubgroupShuffleXorINTEL
    .{ 5575, 5569 }, // OpSubgroupBlockReadINTEL
    .{ 5576, 5569 }, // OpSubgroupBlockWriteINTEL
    .{ 5577, 5570 }, // OpSubgroupImageBlockReadINTEL
    .{ 5578, 5570 }, // OpSubgroupImageBlockWriteINTEL
    .{ 5580, 5579 }, // OpSubgroupImageMediaBlockReadINTEL
    .{ 5581, 5579 }, // OpSubgroupImageMediaBlockWriteINTEL
    .{ 5585, 5584 }, // OpUCountLeadingZerosINTEL
    .{ 5586, 5584 }, // OpUCountTrailingZerosINTEL
    .{ 5587, 5584 }, // OpAbsISubINTEL
    .{ 5588, 5584 }, // OpAbsUSubINTEL
    .{ 5589, 5584 }, // OpIAddSatINTEL
    .{ 5590, 5584 }, // OpUAddSatINTEL
    .{ 5591, 5584 }, // OpIAverageINTEL
    .{ 5592, 5584 }, // OpUAverageINTEL
    .{ 5593, 5584 }, // OpIAverageRoundedINTEL
    .{ 5594, 5584 }, // OpUAverageRoundedINTEL
    .{ 5595, 5584 }, // OpISubSatINTEL
    .{ 5596, 5584 }, // OpUSubSatINTEL
    .{ 5597, 5584 }, // OpIMul32x16INTEL
    .{ 5598, 5584 }, // OpUMul32x16INTEL
    .{ 5600, 5603 }, // OpConstantFunctionPointerINTEL
    .{ 5601, 5603 }, // OpFunctionPointerCallINTEL
    .{ 5609, 5606 }, // OpAsmTargetINTEL
    .{ 5610, 5606 }, // OpAsmINTEL
    .{ 5611, 5606 }, // OpAsmCallINTEL
    .{ 5614, 5616 }, // OpAtomicFMinEXT
    .{ 5615, 5616 }, // OpAtomicFMaxEXT
    .{ 5630, 5629 }, // OpAssumeTrueKHR
    .{ 5631, 5629 }, // OpExpectKHR
    .{ 5699, 5696 }, // OpVmeImageINTEL
    .{ 5700, 5696 }, // OpTypeVmeImageINTEL
    .{ 5701, 5696 }, // OpTypeAvcImePayloadINTEL
    .{ 5702, 5696 }, // OpTypeAvcRefPayloadINTEL
    .{ 5703, 5696 }, // OpTypeAvcSicPayloadINTEL
    .{ 5704, 5696 }, // OpTypeAvcMcePayloadINTEL
    .{ 5705, 5696 }, // OpTypeAvcMceResultINTEL
    .{ 5706, 5696 }, // OpTypeAvcImeResultINTEL
    .{ 5707, 5696 }, // OpTypeAvcImeResultSingleReferenceStreamoutINTEL
    .{ 5708, 5696 }, // OpTypeAvcImeResultDualReferenceStreamoutINTEL
    .{ 5709, 5696 }, // OpTypeAvcImeSingleReferenceStreaminINTEL
    .{ 5710, 5696 }, // OpTypeAvcImeDualReferenceStreaminINTEL
    .{ 5711, 5696 }, // OpTypeAvcRefResultINTEL
    .{ 5712, 5696 }, // OpTypeAvcSicResultINTEL
    .{ 5713, 5696 }, // OpSubgroupAvcMceGetDefaultInterBaseMultiReferencePenaltyINTEL
    .{ 5714, 5696 }, // OpSubgroupAvcMceSetInterBaseMultiReferencePenaltyINTEL
    .{ 5715, 5696 }, // OpSubgroupAvcMceGetDefaultInterShapePenaltyINTEL
    .{ 5716, 5696 }, // OpSubgroupAvcMceSetInterShapePenaltyINTEL
    .{ 5717, 5696 }, // OpSubgroupAvcMceGetDefaultInterDirectionPenaltyINTEL
    .{ 5718, 5696 }, // OpSubgroupAvcMceSetInterDirectionPenaltyINTEL
    .{ 5719, 5696 }, // OpSubgroupAvcMceGetDefaultIntraLumaShapePenaltyINTEL
    .{ 5720, 5696 }, // OpSubgroupAvcMceGetDefaultInterMotionVectorCostTableINTEL
    .{ 5721, 5696 }, // OpSubgroupAvcMceGetDefaultHighPenaltyCostTableINTEL
    .{ 5722, 5696 }, // OpSubgroupAvcMceGetDefaultMediumPenaltyCostTableINTEL
    .{ 5723, 5696 }, // OpSubgroupAvcMceGetDefaultLowPenaltyCostTableINTEL
    .{ 5724, 5696 }, // OpSubgroupAvcMceSetMotionVectorCostFunctionINTEL
    .{ 5725, 5696 }, // OpSubgroupAvcMceGetDefaultIntraLumaModePenaltyINTEL
    .{ 5726, 5696 }, // OpSubgroupAvcMceGetDefaultNonDcLumaIntraPenaltyINTEL
    .{ 5727, 5696 }, // OpSubgroupAvcMceGetDefaultIntraChromaModeBasePenaltyINTEL
    .{ 5728, 5696 }, // OpSubgroupAvcMceSetAcOnlyHaarINTEL
    .{ 5729, 5696 }, // OpSubgroupAvcMceSetSourceInterlacedFieldPolarityINTEL
    .{ 5730, 5696 }, // OpSubgroupAvcMceSetSingleReferenceInterlacedFieldPolarityINTEL
    .{ 5731, 5696 }, // OpSubgroupAvcMceSetDualReferenceInterlacedFieldPolaritiesINTEL
    .{ 5732, 5696 }, // OpSubgroupAvcMceConvertToImePayloadINTEL
    .{ 5733, 5696 }, // OpSubgroupAvcMceConvertToImeResultINTEL
    .{ 5734, 5696 }, // OpSubgroupAvcMceConvertToRefPayloadINTEL
    .{ 5735, 5696 }, // OpSubgroupAvcMceConvertToRefResultINTEL
    .{ 5736, 5696 }, // OpSubgroupAvcMceConvertToSicPayloadINTEL
    .{ 5737, 5696 }, // OpSubgroupAvcMceConvertToSicResultINTEL
    .{ 5738, 5696 }, // OpSubgroupAvcMceGetMotionVectorsINTEL
    .{ 5739, 5696 }, // OpSubgroupAvcMceGetInterDistortionsINTEL
    .{ 5740, 5696 }, // OpSubgroupAvcMceGetBestInterDistortionsINTEL
    .{ 5741, 5696 }, // OpSubgroupAvcMceGetInterMajorShapeINTEL
    .{ 5742, 5696 }, // OpSubgroupAvcMceGetInterMinorShapeINTEL
    .{ 5743, 5696 }, // OpSubgroupAvcMceGetInterDirectionsINTEL
    .{ 5744, 5696 }, // OpSubgroupAvcMceGetInterMotionVectorCountINTEL
    .{ 5745, 5696 }, // OpSubgroupAvcMceGetInterReferenceIdsINTEL
    .{ 5746, 5696 }, // OpSubgroupAvcMceGetInterReferenceInterlacedFieldPolaritiesINTEL
    .{ 5747, 5696 }, // OpSubgroupAvcImeInitializeINTEL
    .{ 5748, 5696 }, // OpSubgroupAvcImeSetSingleReferenceINTEL
    .{ 5749, 5696 }, // OpSubgroupAvcImeSetDualReferenceINTEL
    .{ 5750, 5696 }, // OpSubgroupAvcImeRefWindowSizeINTEL
    .{ 5751, 5696 }, // OpSubgroupAvcImeAdjustRefOffsetINTEL
    .{ 5752, 5696 }, // OpSubgroupAvcImeConvertToMcePayloadINTEL
    .{ 5753, 5696 }, // OpSubgroupAvcImeSetMaxMotionVectorCountINTEL
    .{ 5754, 5696 }, // OpSubgroupAvcImeSetUnidirectionalMixDisableINTEL
    .{ 5755, 5696 }, // OpSubgroupAvcImeSetEarlySearchTerminationThresholdINTEL
    .{ 5756, 5696 }, // OpSubgroupAvcImeSetWeightedSadINTEL
    .{ 5757, 5696 }, // OpSubgroupAvcImeEvaluateWithSingleReferenceINTEL
    .{ 5758, 5696 }, // OpSubgroupAvcImeEvaluateWithDualReferenceINTEL
    .{ 5759, 5696 }, // OpSubgroupAvcImeEvaluateWithSingleReferenceStreaminINTEL
    .{ 5760, 5696 }, // OpSubgroupAvcImeEvaluateWithDualReferenceStreaminINTEL
    .{ 5761, 5696 }, // OpSubgroupAvcImeEvaluateWithSingleReferenceStreamoutINTEL
    .{ 5762, 5696 }, // OpSubgroupAvcImeEvaluateWithDualReferenceStreamoutINTEL
    .{ 5763, 5696 }, // OpSubgroupAvcImeEvaluateWithSingleReferenceStreaminoutINTEL
    .{ 5764, 5696 }, // OpSubgroupAvcImeEvaluateWithDualReferenceStreaminoutINTEL
    .{ 5765, 5696 }, // OpSubgroupAvcImeConvertToMceResultINTEL
    .{ 5766, 5696 }, // OpSubgroupAvcImeGetSingleReferenceStreaminINTEL
    .{ 5767, 5696 }, // OpSubgroupAvcImeGetDualReferenceStreaminINTEL
    .{ 5768, 5696 }, // OpSubgroupAvcImeStripSingleReferenceStreamoutINTEL
    .{ 5769, 5696 }, // OpSubgroupAvcImeStripDualReferenceStreamoutINTEL
    .{ 5770, 5696 }, // OpSubgroupAvcImeGetStreamoutSingleReferenceMajorShapeMotionVectorsINTEL
    .{ 5771, 5696 }, // OpSubgroupAvcImeGetStreamoutSingleReferenceMajorShapeDistortionsINTEL
    .{ 5772, 5696 }, // OpSubgroupAvcImeGetStreamoutSingleReferenceMajorShapeReferenceIdsINTEL
    .{ 5773, 5696 }, // OpSubgroupAvcImeGetStreamoutDualReferenceMajorShapeMotionVectorsINTEL
    .{ 5774, 5696 }, // OpSubgroupAvcImeGetStreamoutDualReferenceMajorShapeDistortionsINTEL
    .{ 5775, 5696 }, // OpSubgroupAvcImeGetStreamoutDualReferenceMajorShapeReferenceIdsINTEL
    .{ 5776, 5696 }, // OpSubgroupAvcImeGetBorderReachedINTEL
    .{ 5777, 5696 }, // OpSubgroupAvcImeGetTruncatedSearchIndicationINTEL
    .{ 5778, 5696 }, // OpSubgroupAvcImeGetUnidirectionalEarlySearchTerminationINTEL
    .{ 5779, 5696 }, // OpSubgroupAvcImeGetWeightingPatternMinimumMotionVectorINTEL
    .{ 5780, 5696 }, // OpSubgroupAvcImeGetWeightingPatternMinimumDistortionINTEL
    .{ 5781, 5696 }, // OpSubgroupAvcFmeInitializeINTEL
    .{ 5782, 5696 }, // OpSubgroupAvcBmeInitializeINTEL
    .{ 5783, 5696 }, // OpSubgroupAvcRefConvertToMcePayloadINTEL
    .{ 5784, 5696 }, // OpSubgroupAvcRefSetBidirectionalMixDisableINTEL
    .{ 5785, 5696 }, // OpSubgroupAvcRefSetBilinearFilterEnableINTEL
    .{ 5786, 5696 }, // OpSubgroupAvcRefEvaluateWithSingleReferenceINTEL
    .{ 5787, 5696 }, // OpSubgroupAvcRefEvaluateWithDualReferenceINTEL
    .{ 5788, 5696 }, // OpSubgroupAvcRefEvaluateWithMultiReferenceINTEL
    .{ 5789, 5696 }, // OpSubgroupAvcRefEvaluateWithMultiReferenceInterlacedINTEL
    .{ 5790, 5696 }, // OpSubgroupAvcRefConvertToMceResultINTEL
    .{ 5791, 5696 }, // OpSubgroupAvcSicInitializeINTEL
    .{ 5792, 5696 }, // OpSubgroupAvcSicConfigureSkcINTEL
    .{ 5793, 5696 }, // OpSubgroupAvcSicConfigureIpeLumaINTEL
    .{ 5794, 5696 }, // OpSubgroupAvcSicConfigureIpeLumaChromaINTEL
    .{ 5795, 5696 }, // OpSubgroupAvcSicGetMotionVectorMaskINTEL
    .{ 5796, 5696 }, // OpSubgroupAvcSicConvertToMcePayloadINTEL
    .{ 5797, 5696 }, // OpSubgroupAvcSicSetIntraLumaShapePenaltyINTEL
    .{ 5798, 5696 }, // OpSubgroupAvcSicSetIntraLumaModeCostFunctionINTEL
    .{ 5799, 5696 }, // OpSubgroupAvcSicSetIntraChromaModeCostFunctionINTEL
    .{ 5800, 5696 }, // OpSubgroupAvcSicSetBilinearFilterEnableINTEL
    .{ 5801, 5696 }, // OpSubgroupAvcSicSetSkcForwardTransformEnableINTEL
    .{ 5802, 5696 }, // OpSubgroupAvcSicSetBlockBasedRawSkipSadINTEL
    .{ 5803, 5696 }, // OpSubgroupAvcSicEvaluateIpeINTEL
    .{ 5804, 5696 }, // OpSubgroupAvcSicEvaluateWithSingleReferenceINTEL
    .{ 5805, 5696 }, // OpSubgroupAvcSicEvaluateWithDualReferenceINTEL
    .{ 5806, 5696 }, // OpSubgroupAvcSicEvaluateWithMultiReferenceINTEL
    .{ 5807, 5696 }, // OpSubgroupAvcSicEvaluateWithMultiReferenceInterlacedINTEL
    .{ 5808, 5696 }, // OpSubgroupAvcSicConvertToMceResultINTEL
    .{ 5809, 5696 }, // OpSubgroupAvcSicGetIpeLumaShapeINTEL
    .{ 5810, 5696 }, // OpSubgroupAvcSicGetBestIpeLumaDistortionINTEL
    .{ 5811, 5696 }, // OpSubgroupAvcSicGetBestIpeChromaDistortionINTEL
    .{ 5812, 5696 }, // OpSubgroupAvcSicGetPackedIpeLumaModesINTEL
    .{ 5813, 5696 }, // OpSubgroupAvcSicGetIpeChromaModeINTEL
    .{ 5814, 5696 }, // OpSubgroupAvcSicGetPackedSkcLumaCountThresholdINTEL
    .{ 5815, 5696 }, // OpSubgroupAvcSicGetPackedSkcLumaSumThresholdINTEL
    .{ 5816, 5696 }, // OpSubgroupAvcSicGetInterRawSadsINTEL
    .{ 5818, 5817 }, // OpVariableLengthArrayINTEL
    .{ 5819, 5817 }, // OpSaveMemoryINTEL
    .{ 5820, 5817 }, // OpRestoreMemoryINTEL
    .{ 5840, 5845 }, // OpArbitraryFloatSinCosPiALTERA
    .{ 5841, 5845 }, // OpArbitraryFloatCastALTERA
    .{ 5842, 5845 }, // OpArbitraryFloatCastFromIntALTERA
    .{ 5843, 5845 }, // OpArbitraryFloatCastToIntALTERA
    .{ 5846, 5845 }, // OpArbitraryFloatAddALTERA
    .{ 5847, 5845 }, // OpArbitraryFloatSubALTERA
    .{ 5848, 5845 }, // OpArbitraryFloatMulALTERA
    .{ 5849, 5845 }, // OpArbitraryFloatDivALTERA
    .{ 5850, 5845 }, // OpArbitraryFloatGTALTERA
    .{ 5851, 5845 }, // OpArbitraryFloatGEALTERA
    .{ 5852, 5845 }, // OpArbitraryFloatLTALTERA
    .{ 5853, 5845 }, // OpArbitraryFloatLEALTERA
    .{ 5854, 5845 }, // OpArbitraryFloatEQALTERA
    .{ 5855, 5845 }, // OpArbitraryFloatRecipALTERA
    .{ 5856, 5845 }, // OpArbitraryFloatRSqrtALTERA
    .{ 5857, 5845 }, // OpArbitraryFloatCbrtALTERA
    .{ 5858, 5845 }, // OpArbitraryFloatHypotALTERA
    .{ 5859, 5845 }, // OpArbitraryFloatSqrtALTERA
    .{ 5860, 5845 }, // OpArbitraryFloatLogINTEL
    .{ 5861, 5845 }, // OpArbitraryFloatLog2INTEL
    .{ 5862, 5845 }, // OpArbitraryFloatLog10INTEL
    .{ 5863, 5845 }, // OpArbitraryFloatLog1pINTEL
    .{ 5864, 5845 }, // OpArbitraryFloatExpINTEL
    .{ 5865, 5845 }, // OpArbitraryFloatExp2INTEL
    .{ 5866, 5845 }, // OpArbitraryFloatExp10INTEL
    .{ 5867, 5845 }, // OpArbitraryFloatExpm1INTEL
    .{ 5868, 5845 }, // OpArbitraryFloatSinINTEL
    .{ 5869, 5845 }, // OpArbitraryFloatCosINTEL
    .{ 5870, 5845 }, // OpArbitraryFloatSinCosINTEL
    .{ 5871, 5845 }, // OpArbitraryFloatSinPiINTEL
    .{ 5872, 5845 }, // OpArbitraryFloatCosPiINTEL
    .{ 5873, 5845 }, // OpArbitraryFloatASinINTEL
    .{ 5874, 5845 }, // OpArbitraryFloatASinPiINTEL
    .{ 5875, 5845 }, // OpArbitraryFloatACosINTEL
    .{ 5876, 5845 }, // OpArbitraryFloatACosPiINTEL
    .{ 5877, 5845 }, // OpArbitraryFloatATanINTEL
    .{ 5878, 5845 }, // OpArbitraryFloatATanPiINTEL
    .{ 5879, 5845 }, // OpArbitraryFloatATan2INTEL
    .{ 5880, 5845 }, // OpArbitraryFloatPowINTEL
    .{ 5881, 5845 }, // OpArbitraryFloatPowRINTEL
    .{ 5882, 5845 }, // OpArbitraryFloatPowNINTEL
    .{ 5887, 5886 }, // OpLoopControlINTEL
    .{ 5911, 5910 }, // OpAliasDomainDeclINTEL
    .{ 5912, 5910 }, // OpAliasScopeDeclINTEL
    .{ 5913, 5910 }, // OpAliasScopeListDeclINTEL
    .{ 5923, 5922 }, // OpFixedSqrtALTERA
    .{ 5924, 5922 }, // OpFixedRecipALTERA
    .{ 5925, 5922 }, // OpFixedRsqrtALTERA
    .{ 5926, 5922 }, // OpFixedSinALTERA
    .{ 5927, 5922 }, // OpFixedCosALTERA
    .{ 5928, 5922 }, // OpFixedSinCosALTERA
    .{ 5929, 5922 }, // OpFixedSinPiALTERA
    .{ 5930, 5922 }, // OpFixedCosPiALTERA
    .{ 5931, 5922 }, // OpFixedSinCosPiALTERA
    .{ 5932, 5922 }, // OpFixedLogALTERA
    .{ 5933, 5922 }, // OpFixedExpALTERA
    .{ 5934, 5935 }, // OpPtrCastToCrossWorkgroupALTERA
    .{ 5938, 5935 }, // OpCrossWorkgroupCastToPtrALTERA
    .{ 5946, 5945 }, // OpReadPipeBlockingALTERA
    .{ 5947, 5945 }, // OpWritePipeBlockingALTERA
    .{ 5949, 5948 }, // OpFPGARegALTERA
    .{ 6016, 4472 }, // OpRayQueryGetRayTMinKHR
    .{ 6017, 4472 }, // OpRayQueryGetRayFlagsKHR
    .{ 6018, 4472 }, // OpRayQueryGetIntersectionTKHR
    .{ 6019, 4472 }, // OpRayQueryGetIntersectionInstanceCustomIndexKHR
    .{ 6020, 4472 }, // OpRayQueryGetIntersectionInstanceIdKHR
    .{ 6021, 4472 }, // OpRayQueryGetIntersectionInstanceShaderBindingTableRecordOffsetKHR
    .{ 6022, 4472 }, // OpRayQueryGetIntersectionGeometryIndexKHR
    .{ 6023, 4472 }, // OpRayQueryGetIntersectionPrimitiveIndexKHR
    .{ 6024, 4472 }, // OpRayQueryGetIntersectionBarycentricsKHR
    .{ 6025, 4472 }, // OpRayQueryGetIntersectionFrontFaceKHR
    .{ 6026, 4472 }, // OpRayQueryGetIntersectionCandidateAABBOpaqueKHR
    .{ 6027, 4472 }, // OpRayQueryGetIntersectionObjectRayDirectionKHR
    .{ 6028, 4472 }, // OpRayQueryGetIntersectionObjectRayOriginKHR
    .{ 6029, 4472 }, // OpRayQueryGetWorldRayDirectionKHR
    .{ 6030, 4472 }, // OpRayQueryGetWorldRayOriginKHR
    .{ 6031, 4472 }, // OpRayQueryGetIntersectionObjectToWorldKHR
    .{ 6032, 4472 }, // OpRayQueryGetIntersectionWorldToObjectKHR
    .{ 6035, 6095 }, // OpAtomicFAddEXT
    .{ 6086, 5617 }, // OpTypeBufferSurfaceINTEL
    .{ 6090, 6089 }, // OpTypeStructContinuedINTEL
    .{ 6091, 6089 }, // OpConstantCompositeContinuedINTEL
    .{ 6092, 6089 }, // OpSpecConstantCompositeContinuedINTEL
    .{ 6096, 6089 }, // OpCompositeConstructContinuedINTEL
    .{ 6116, 6115 }, // OpConvertFToBF16INTEL
    .{ 6117, 6115 }, // OpConvertBF16ToFINTEL
    .{ 6142, 6141 }, // OpControlBarrierArriveEXT
    .{ 6143, 6141 }, // OpControlBarrierWaitEXT
    .{ 6145, 6144 }, // OpArithmeticFenceEXT
    .{ 6163, 6162 }, // OpTaskSequenceCreateALTERA
    .{ 6164, 6162 }, // OpTaskSequenceAsyncALTERA
    .{ 6165, 6162 }, // OpTaskSequenceGetALTERA
    .{ 6166, 6162 }, // OpTaskSequenceReleaseALTERA
    .{ 6199, 6162 }, // OpTypeTaskSequenceALTERA
    .{ 6221, 6220 }, // OpSubgroupBlockPrefetchINTEL
    .{ 6231, 6228 }, // OpSubgroup2DBlockLoadINTEL
    .{ 6232, 6229 }, // OpSubgroup2DBlockLoadTransformINTEL
    .{ 6233, 6230 }, // OpSubgroup2DBlockLoadTransposeINTEL
    .{ 6234, 6228 }, // OpSubgroup2DBlockPrefetchINTEL
    .{ 6235, 6228 }, // OpSubgroup2DBlockStoreINTEL
    .{ 6237, 6236 }, // OpSubgroupMatrixMultiplyAccumulateINTEL
    .{ 6242, 6241 }, // OpBitwiseFunctionINTEL
    .{ 6244, 6243 }, // OpUntypedVariableLengthArrayINTEL
    .{ 6248, 6245 }, // OpConditionalExtensionINTEL
    .{ 6249, 6245 }, // OpConditionalEntryPointINTEL
    .{ 6250, 6245 }, // OpConditionalCapabilityINTEL
    .{ 6251, 6246 }, // OpSpecConstantTargetINTEL
    .{ 6252, 6246 }, // OpSpecConstantArchitectureINTEL
    .{ 6253, 6246 }, // OpSpecConstantCapabilitiesINTEL
    .{ 6254, 6245 }, // OpConditionalCopyObjectINTEL
    .{ 6258, 6257 }, // OpPredicatedLoadINTEL
    .{ 6259, 6257 }, // OpPredicatedStoreINTEL
    .{ 6401, 6400 }, // OpGroupIMulKHR
    .{ 6402, 6400 }, // OpGroupFMulKHR
    .{ 6403, 6400 }, // OpGroupBitwiseAndKHR
    .{ 6404, 6400 }, // OpGroupBitwiseOrKHR
    .{ 6405, 6400 }, // OpGroupBitwiseXorKHR
    .{ 6406, 6400 }, // OpGroupLogicalAndKHR
    .{ 6407, 6400 }, // OpGroupLogicalOrKHR
    .{ 6408, 6400 }, // OpGroupLogicalXorKHR
    .{ 6426, 6425 }, // OpRoundFToTF32INTEL
    .{ 6428, 6427 }, // OpMaskedGatherINTEL
    .{ 6429, 6427 }, // OpMaskedScatterINTEL
    .{ 6529, 6528 }, // OpConvertHandleToImageINTEL
    .{ 6530, 6528 }, // OpConvertHandleToSamplerINTEL
    .{ 6531, 6528 }, // OpConvertHandleToSampledImageINTEL
    .{ 6916, 6912 }, // OpFDot2MixAcc32VALVE
    .{ 6917, 6913 }, // OpFDot2MixAcc16VALVE
    .{ 6918, 6915 }, // OpFDot4MixAcc32VALVE
};

/// An enumerant's capability (0: none), extension ("" : none), and the
/// SPIR-V version (major * 100 + minor) that made the extension core.
pub const Need = struct { value: u32, cap: u32, ext: []const u8, core: u32 };

pub const builtins = [_]Need{
    .{ .value = 0, .cap = 1, .ext = "", .core = 100 }, // Position
    .{ .value = 1, .cap = 1, .ext = "", .core = 100 }, // PointSize
    .{ .value = 3, .cap = 32, .ext = "", .core = 100 }, // ClipDistance
    .{ .value = 4, .cap = 33, .ext = "", .core = 100 }, // CullDistance
    .{ .value = 5, .cap = 1, .ext = "", .core = 100 }, // VertexId
    .{ .value = 6, .cap = 1, .ext = "", .core = 100 }, // InstanceId
    .{ .value = 7, .cap = 2, .ext = "", .core = 100 }, // PrimitiveId
    .{ .value = 8, .cap = 2, .ext = "", .core = 100 }, // InvocationId
    .{ .value = 9, .cap = 2, .ext = "", .core = 100 }, // Layer
    .{ .value = 10, .cap = 57, .ext = "", .core = 100 }, // ViewportIndex
    .{ .value = 11, .cap = 3, .ext = "", .core = 100 }, // TessLevelOuter
    .{ .value = 12, .cap = 3, .ext = "", .core = 100 }, // TessLevelInner
    .{ .value = 13, .cap = 3, .ext = "", .core = 100 }, // TessCoord
    .{ .value = 14, .cap = 3, .ext = "", .core = 100 }, // PatchVertices
    .{ .value = 15, .cap = 1, .ext = "", .core = 100 }, // FragCoord
    .{ .value = 16, .cap = 1, .ext = "", .core = 100 }, // PointCoord
    .{ .value = 17, .cap = 1, .ext = "", .core = 100 }, // FrontFacing
    .{ .value = 18, .cap = 35, .ext = "", .core = 100 }, // SampleId
    .{ .value = 19, .cap = 35, .ext = "", .core = 100 }, // SamplePosition
    .{ .value = 20, .cap = 1, .ext = "", .core = 100 }, // SampleMask
    .{ .value = 22, .cap = 1, .ext = "", .core = 100 }, // FragDepth
    .{ .value = 23, .cap = 1, .ext = "", .core = 100 }, // HelperInvocation
    .{ .value = 30, .cap = 6, .ext = "", .core = 100 }, // WorkDim
    .{ .value = 31, .cap = 6, .ext = "", .core = 100 }, // GlobalSize
    .{ .value = 32, .cap = 6, .ext = "", .core = 100 }, // EnqueuedWorkgroupSize
    .{ .value = 33, .cap = 6, .ext = "", .core = 100 }, // GlobalOffset
    .{ .value = 34, .cap = 6, .ext = "", .core = 100 }, // GlobalLinearId
    .{ .value = 36, .cap = 6, .ext = "", .core = 100 }, // SubgroupSize
    .{ .value = 37, .cap = 6, .ext = "", .core = 100 }, // SubgroupMaxSize
    .{ .value = 38, .cap = 6, .ext = "", .core = 100 }, // NumSubgroups
    .{ .value = 39, .cap = 6, .ext = "", .core = 100 }, // NumEnqueuedSubgroups
    .{ .value = 40, .cap = 6, .ext = "", .core = 100 }, // SubgroupId
    .{ .value = 41, .cap = 6, .ext = "", .core = 100 }, // SubgroupLocalInvocationId
    .{ .value = 42, .cap = 1, .ext = "", .core = 100 }, // VertexIndex
    .{ .value = 43, .cap = 1, .ext = "", .core = 100 }, // InstanceIndex
    .{ .value = 4160, .cap = 4165, .ext = "", .core = 100 }, // CoreIDARM
    .{ .value = 4161, .cap = 4165, .ext = "", .core = 100 }, // CoreCountARM
    .{ .value = 4162, .cap = 4165, .ext = "", .core = 100 }, // CoreMaxIDARM
    .{ .value = 4163, .cap = 4165, .ext = "", .core = 100 }, // WarpIDARM
    .{ .value = 4164, .cap = 4165, .ext = "", .core = 100 }, // WarpMaxIDARM
    .{ .value = 4416, .cap = 4423, .ext = "SPV_KHR_shader_ballot", .core = 103 }, // SubgroupEqMask
    .{ .value = 4417, .cap = 4423, .ext = "SPV_KHR_shader_ballot", .core = 103 }, // SubgroupGeMask
    .{ .value = 4418, .cap = 4423, .ext = "SPV_KHR_shader_ballot", .core = 103 }, // SubgroupGtMask
    .{ .value = 4419, .cap = 4423, .ext = "SPV_KHR_shader_ballot", .core = 103 }, // SubgroupLeMask
    .{ .value = 4420, .cap = 4423, .ext = "SPV_KHR_shader_ballot", .core = 103 }, // SubgroupLtMask
    .{ .value = 4424, .cap = 4427, .ext = "SPV_KHR_shader_draw_parameters", .core = 103 }, // BaseVertex
    .{ .value = 4425, .cap = 4427, .ext = "SPV_KHR_shader_draw_parameters", .core = 103 }, // BaseInstance
    .{ .value = 4426, .cap = 4427, .ext = "SPV_KHR_shader_draw_parameters", .core = 103 }, // DrawIndex
    .{ .value = 4432, .cap = 4422, .ext = "SPV_KHR_fragment_shading_rate", .core = 999 }, // PrimitiveShadingRateKHR
    .{ .value = 4438, .cap = 4437, .ext = "SPV_KHR_device_group", .core = 103 }, // DeviceIndex
    .{ .value = 4440, .cap = 4439, .ext = "SPV_KHR_multiview", .core = 103 }, // ViewIndex
    .{ .value = 4444, .cap = 4422, .ext = "SPV_KHR_fragment_shading_rate", .core = 999 }, // ShadingRateKHR
    .{ .value = 4492, .cap = 4495, .ext = "", .core = 999 }, // TileOffsetQCOM
    .{ .value = 4493, .cap = 4495, .ext = "", .core = 999 }, // TileDimensionQCOM
    .{ .value = 4494, .cap = 4495, .ext = "", .core = 999 }, // TileApronSizeQCOM
    .{ .value = 4992, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // BaryCoordNoPerspAMD
    .{ .value = 4993, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // BaryCoordNoPerspCentroidAMD
    .{ .value = 4994, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // BaryCoordNoPerspSampleAMD
    .{ .value = 4995, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // BaryCoordSmoothAMD
    .{ .value = 4996, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // BaryCoordSmoothCentroidAMD
    .{ .value = 4997, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // BaryCoordSmoothSampleAMD
    .{ .value = 4998, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // BaryCoordPullModelAMD
    .{ .value = 5014, .cap = 5013, .ext = "SPV_EXT_shader_stencil_export", .core = 999 }, // FragStencilRefEXT
    .{ .value = 5021, .cap = 5067, .ext = "", .core = 999 }, // RemainingRecursionLevelsAMDX
    .{ .value = 5073, .cap = 5067, .ext = "", .core = 999 }, // ShaderIndexAMDX
    .{ .value = 5122, .cap = 5128, .ext = "", .core = 999 }, // SamplerHeapEXT
    .{ .value = 5123, .cap = 5128, .ext = "", .core = 999 }, // ResourceHeapEXT
    .{ .value = 5253, .cap = 5255, .ext = "SPV_NV_viewport_array2", .core = 999 }, // ViewportMaskNV
    .{ .value = 5257, .cap = 5259, .ext = "SPV_NV_stereo_view_rendering", .core = 999 }, // SecondaryPositionNV
    .{ .value = 5258, .cap = 5259, .ext = "SPV_NV_stereo_view_rendering", .core = 999 }, // SecondaryViewportMaskNV
    .{ .value = 5261, .cap = 5260, .ext = "SPV_NVX_multiview_per_view_attributes", .core = 999 }, // PositionPerViewNV
    .{ .value = 5262, .cap = 5260, .ext = "SPV_NVX_multiview_per_view_attributes", .core = 999 }, // ViewportMaskPerViewNV
    .{ .value = 5264, .cap = 5265, .ext = "SPV_EXT_fragment_fully_covered", .core = 999 }, // FullyCoveredEXT
    .{ .value = 5274, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // TaskCountNV
    .{ .value = 5275, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // PrimitiveCountNV
    .{ .value = 5276, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // PrimitiveIndicesNV
    .{ .value = 5277, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // ClipDistancePerViewNV
    .{ .value = 5278, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // CullDistancePerViewNV
    .{ .value = 5279, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // LayerPerViewNV
    .{ .value = 5280, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // MeshViewCountNV
    .{ .value = 5281, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // MeshViewIndicesNV
    .{ .value = 5286, .cap = 5284, .ext = "SPV_NV_fragment_shader_barycentric", .core = 999 }, // BaryCoordKHR
    .{ .value = 5287, .cap = 5284, .ext = "SPV_NV_fragment_shader_barycentric", .core = 999 }, // BaryCoordNoPerspKHR
    .{ .value = 5292, .cap = 5291, .ext = "SPV_EXT_fragment_invocation_density", .core = 999 }, // FragSizeEXT
    .{ .value = 5293, .cap = 5291, .ext = "SPV_EXT_fragment_invocation_density", .core = 999 }, // FragInvocationCountEXT
    .{ .value = 5294, .cap = 5283, .ext = "SPV_EXT_mesh_shader", .core = 999 }, // PrimitivePointIndicesEXT
    .{ .value = 5295, .cap = 5283, .ext = "SPV_EXT_mesh_shader", .core = 999 }, // PrimitiveLineIndicesEXT
    .{ .value = 5296, .cap = 5283, .ext = "SPV_EXT_mesh_shader", .core = 999 }, // PrimitiveTriangleIndicesEXT
    .{ .value = 5299, .cap = 5283, .ext = "SPV_EXT_mesh_shader", .core = 999 }, // CullPrimitiveEXT
    .{ .value = 5319, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // LaunchIdKHR
    .{ .value = 5320, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // LaunchSizeKHR
    .{ .value = 5321, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // WorldRayOriginKHR
    .{ .value = 5322, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // WorldRayDirectionKHR
    .{ .value = 5323, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // ObjectRayOriginKHR
    .{ .value = 5324, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // ObjectRayDirectionKHR
    .{ .value = 5325, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // RayTminKHR
    .{ .value = 5326, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // RayTmaxKHR
    .{ .value = 5327, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // InstanceCustomIndexKHR
    .{ .value = 5330, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // ObjectToWorldKHR
    .{ .value = 5331, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // WorldToObjectKHR
    .{ .value = 5332, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // HitTNV
    .{ .value = 5333, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // HitKindKHR
    .{ .value = 5334, .cap = 5341, .ext = "SPV_NV_ray_tracing_motion_blur", .core = 999 }, // CurrentRayTimeNV
    .{ .value = 5335, .cap = 5336, .ext = "", .core = 999 }, // HitTriangleVertexPositionsKHR
    .{ .value = 5337, .cap = 5409, .ext = "", .core = 999 }, // HitMicroTriangleVertexPositionsNV
    .{ .value = 5344, .cap = 5409, .ext = "", .core = 999 }, // HitMicroTriangleVertexBarycentricsNV
    .{ .value = 5351, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // IncomingRayFlagsKHR
    .{ .value = 5352, .cap = 4479, .ext = "SPV_KHR_ray_tracing", .core = 999 }, // RayGeometryIndexKHR
    .{ .value = 5359, .cap = 5418, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // HitIsSphereNV
    .{ .value = 5360, .cap = 5419, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // HitIsLSSNV
    .{ .value = 5361, .cap = 5418, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // HitSpherePositionNV
    .{ .value = 5374, .cap = 5373, .ext = "SPV_NV_shader_sm_builtins", .core = 999 }, // WarpsPerSMNV
    .{ .value = 5375, .cap = 5373, .ext = "SPV_NV_shader_sm_builtins", .core = 999 }, // SMCountNV
    .{ .value = 5376, .cap = 5373, .ext = "SPV_NV_shader_sm_builtins", .core = 999 }, // WarpIDNV
    .{ .value = 5377, .cap = 5373, .ext = "SPV_NV_shader_sm_builtins", .core = 999 }, // SMIDNV
    .{ .value = 5396, .cap = 5419, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // HitLSSPositionsNV
    .{ .value = 5405, .cap = 5409, .ext = "", .core = 999 }, // HitKindFrontFacingMicroTriangleNV
    .{ .value = 5406, .cap = 5409, .ext = "", .core = 999 }, // HitKindBackFacingMicroTriangleNV
    .{ .value = 5420, .cap = 5418, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // HitSphereRadiusNV
    .{ .value = 5421, .cap = 5419, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // HitLSSRadiiNV
    .{ .value = 5436, .cap = 5437, .ext = "SPV_NV_cluster_acceleration_structure", .core = 999 }, // ClusterIDNV
    .{ .value = 6021, .cap = 6020, .ext = "SPV_KHR_ray_cull_mask", .core = 999 }, // CullMaskKHR
};

pub const decorations = [_]Need{
    .{ .value = 0, .cap = 1, .ext = "", .core = 100 }, // RelaxedPrecision
    .{ .value = 1, .cap = 1, .ext = "", .core = 100 }, // SpecId
    .{ .value = 2, .cap = 1, .ext = "", .core = 100 }, // Block
    .{ .value = 3, .cap = 1, .ext = "", .core = 100 }, // BufferBlock
    .{ .value = 6, .cap = 1, .ext = "", .core = 100 }, // ArrayStride
    .{ .value = 8, .cap = 1, .ext = "", .core = 100 }, // GLSLShared
    .{ .value = 9, .cap = 1, .ext = "", .core = 100 }, // GLSLPacked
    .{ .value = 10, .cap = 6, .ext = "", .core = 100 }, // CPacked
    .{ .value = 13, .cap = 1, .ext = "", .core = 100 }, // NoPerspective
    .{ .value = 14, .cap = 1, .ext = "", .core = 100 }, // Flat
    .{ .value = 15, .cap = 3, .ext = "", .core = 100 }, // Patch
    .{ .value = 16, .cap = 1, .ext = "", .core = 100 }, // Centroid
    .{ .value = 17, .cap = 35, .ext = "", .core = 100 }, // Sample
    .{ .value = 18, .cap = 1, .ext = "", .core = 100 }, // Invariant
    .{ .value = 22, .cap = 6, .ext = "", .core = 100 }, // Constant
    .{ .value = 26, .cap = 1, .ext = "", .core = 100 }, // Uniform
    .{ .value = 27, .cap = 1, .ext = "", .core = 104 }, // UniformId
    .{ .value = 28, .cap = 6, .ext = "", .core = 100 }, // SaturatedConversion
    .{ .value = 29, .cap = 54, .ext = "", .core = 100 }, // Stream
    .{ .value = 30, .cap = 1, .ext = "", .core = 100 }, // Location
    .{ .value = 31, .cap = 1, .ext = "", .core = 100 }, // Component
    .{ .value = 32, .cap = 1, .ext = "", .core = 100 }, // Index
    .{ .value = 33, .cap = 1, .ext = "", .core = 100 }, // Binding
    .{ .value = 34, .cap = 1, .ext = "", .core = 100 }, // DescriptorSet
    .{ .value = 35, .cap = 1, .ext = "", .core = 100 }, // Offset
    .{ .value = 36, .cap = 53, .ext = "", .core = 100 }, // XfbBuffer
    .{ .value = 37, .cap = 53, .ext = "", .core = 100 }, // XfbStride
    .{ .value = 38, .cap = 6, .ext = "", .core = 100 }, // FuncParamAttr
    .{ .value = 40, .cap = 6, .ext = "", .core = 100 }, // FPFastMathMode
    .{ .value = 41, .cap = 5, .ext = "", .core = 100 }, // LinkageAttributes
    .{ .value = 42, .cap = 1, .ext = "", .core = 100 }, // NoContraction
    .{ .value = 43, .cap = 40, .ext = "", .core = 100 }, // InputAttachmentIndex
    .{ .value = 44, .cap = 6, .ext = "", .core = 100 }, // Alignment
    .{ .value = 45, .cap = 4, .ext = "", .core = 101 }, // MaxByteOffset
    .{ .value = 46, .cap = 6, .ext = "", .core = 102 }, // AlignmentId
    .{ .value = 47, .cap = 4, .ext = "", .core = 102 }, // MaxByteOffsetId
    .{ .value = 4216, .cap = 4212, .ext = "", .core = 999 }, // SaturatedToLargestFloat8NormalConversionEXT
    .{ .value = 4469, .cap = 0, .ext = "SPV_KHR_no_integer_wrap_decoration", .core = 104 }, // NoSignedWrap
    .{ .value = 4470, .cap = 0, .ext = "SPV_KHR_no_integer_wrap_decoration", .core = 104 }, // NoUnsignedWrap
    .{ .value = 4487, .cap = 0, .ext = "SPV_QCOM_image_processing", .core = 999 }, // WeightTextureQCOM
    .{ .value = 4488, .cap = 0, .ext = "SPV_QCOM_image_processing", .core = 999 }, // BlockMatchTextureQCOM
    .{ .value = 4499, .cap = 0, .ext = "SPV_QCOM_image_processing2", .core = 999 }, // BlockMatchSamplerQCOM
    .{ .value = 4999, .cap = 0, .ext = "SPV_AMD_shader_explicit_vertex_parameter", .core = 999 }, // ExplicitInterpAMD
    .{ .value = 5019, .cap = 5067, .ext = "", .core = 999 }, // NodeSharesPayloadLimitsWithAMDX
    .{ .value = 5020, .cap = 5067, .ext = "", .core = 999 }, // NodeMaxPayloadsAMDX
    .{ .value = 5078, .cap = 5067, .ext = "", .core = 999 }, // TrackFinishWritingAMDX
    .{ .value = 5091, .cap = 5067, .ext = "", .core = 999 }, // PayloadNodeNameAMDX
    .{ .value = 5098, .cap = 5067, .ext = "", .core = 999 }, // PayloadNodeBaseIndexAMDX
    .{ .value = 5099, .cap = 5067, .ext = "", .core = 999 }, // PayloadNodeSparseArrayAMDX
    .{ .value = 5100, .cap = 5067, .ext = "", .core = 999 }, // PayloadNodeArraySizeAMDX
    .{ .value = 5105, .cap = 5067, .ext = "", .core = 999 }, // PayloadDispatchIndirectAMDX
    .{ .value = 5124, .cap = 5128, .ext = "", .core = 999 }, // ArrayStrideIdEXT
    .{ .value = 5125, .cap = 5128, .ext = "", .core = 999 }, // OffsetIdEXT
    .{ .value = 5145, .cap = 5146, .ext = "", .core = 999 }, // UTFEncodedKHR
    .{ .value = 5248, .cap = 5249, .ext = "SPV_NV_sample_mask_override_coverage", .core = 999 }, // OverrideCoverageNV
    .{ .value = 5250, .cap = 5251, .ext = "SPV_NV_geometry_shader_passthrough", .core = 999 }, // PassthroughNV
    .{ .value = 5252, .cap = 5255, .ext = "", .core = 999 }, // ViewportRelativeNV
    .{ .value = 5256, .cap = 5259, .ext = "SPV_NV_stereo_view_rendering", .core = 999 }, // SecondaryViewportRelativeNV
    .{ .value = 5271, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // PerPrimitiveEXT
    .{ .value = 5272, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // PerViewNV
    .{ .value = 5273, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // PerTaskNV
    .{ .value = 5285, .cap = 5284, .ext = "SPV_NV_fragment_shader_barycentric", .core = 999 }, // PerVertexKHR
    .{ .value = 5300, .cap = 5301, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // NonUniform
    .{ .value = 5355, .cap = 5347, .ext = "SPV_EXT_physical_storage_buffer", .core = 105 }, // RestrictPointer
    .{ .value = 5356, .cap = 5347, .ext = "SPV_EXT_physical_storage_buffer", .core = 105 }, // AliasedPointer
    .{ .value = 5358, .cap = 5423, .ext = "", .core = 999 }, // MemberOffsetNV
    .{ .value = 5386, .cap = 5383, .ext = "", .core = 999 }, // HitObjectShaderRecordBufferNV
    .{ .value = 5389, .cap = 5388, .ext = "", .core = 999 }, // HitObjectShaderRecordBufferEXT
    .{ .value = 5397, .cap = 5423, .ext = "", .core = 999 }, // BankNV
    .{ .value = 5398, .cap = 5390, .ext = "", .core = 999 }, // BindlessSamplerNV
    .{ .value = 5399, .cap = 5390, .ext = "", .core = 999 }, // BindlessImageNV
    .{ .value = 5400, .cap = 5390, .ext = "", .core = 999 }, // BoundSamplerNV
    .{ .value = 5401, .cap = 5390, .ext = "", .core = 999 }, // BoundImageNV
    .{ .value = 5599, .cap = 5617, .ext = "", .core = 999 }, // SIMTCallINTEL
    .{ .value = 5602, .cap = 5604, .ext = "SPV_INTEL_function_pointers", .core = 999 }, // ReferencedIndirectlyINTEL
    .{ .value = 5607, .cap = 5606, .ext = "", .core = 999 }, // ClobberINTEL
    .{ .value = 5608, .cap = 5606, .ext = "", .core = 999 }, // SideEffectsINTEL
    .{ .value = 5624, .cap = 5617, .ext = "", .core = 999 }, // VectorComputeVariableINTEL
    .{ .value = 5625, .cap = 5617, .ext = "", .core = 999 }, // FuncParamIOKindINTEL
    .{ .value = 5626, .cap = 5617, .ext = "", .core = 999 }, // VectorComputeFunctionINTEL
    .{ .value = 5627, .cap = 5617, .ext = "", .core = 999 }, // StackCallINTEL
    .{ .value = 5628, .cap = 5617, .ext = "", .core = 999 }, // GlobalVariableOffsetINTEL
    .{ .value = 5634, .cap = 0, .ext = "SPV_GOOGLE_hlsl_functionality1", .core = 104 }, // CounterBuffer
    .{ .value = 5635, .cap = 0, .ext = "SPV_GOOGLE_hlsl_functionality1", .core = 104 }, // UserSemantic
    .{ .value = 5636, .cap = 0, .ext = "SPV_GOOGLE_user_type", .core = 999 }, // UserTypeGOOGLE
    .{ .value = 5822, .cap = 5821, .ext = "", .core = 999 }, // FunctionRoundingModeINTEL
    .{ .value = 5823, .cap = 5821, .ext = "", .core = 999 }, // FunctionDenormModeINTEL
    .{ .value = 5825, .cap = 5824, .ext = "", .core = 999 }, // RegisterALTERA
    .{ .value = 5826, .cap = 5824, .ext = "", .core = 999 }, // MemoryALTERA
    .{ .value = 5827, .cap = 5824, .ext = "", .core = 999 }, // NumbanksALTERA
    .{ .value = 5828, .cap = 5824, .ext = "", .core = 999 }, // BankwidthALTERA
    .{ .value = 5829, .cap = 5824, .ext = "", .core = 999 }, // MaxPrivateCopiesALTERA
    .{ .value = 5830, .cap = 5824, .ext = "", .core = 999 }, // SinglepumpALTERA
    .{ .value = 5831, .cap = 5824, .ext = "", .core = 999 }, // DoublepumpALTERA
    .{ .value = 5832, .cap = 5824, .ext = "", .core = 999 }, // MaxReplicatesALTERA
    .{ .value = 5833, .cap = 5824, .ext = "", .core = 999 }, // SimpleDualPortALTERA
    .{ .value = 5834, .cap = 5824, .ext = "", .core = 999 }, // MergeALTERA
    .{ .value = 5835, .cap = 5824, .ext = "", .core = 999 }, // BankBitsALTERA
    .{ .value = 5836, .cap = 5824, .ext = "", .core = 999 }, // ForcePow2DepthALTERA
    .{ .value = 5883, .cap = 5824, .ext = "", .core = 999 }, // StridesizeALTERA
    .{ .value = 5884, .cap = 5824, .ext = "", .core = 999 }, // WordsizeALTERA
    .{ .value = 5885, .cap = 5824, .ext = "", .core = 999 }, // TrueDualPortALTERA
    .{ .value = 5899, .cap = 5898, .ext = "", .core = 999 }, // BurstCoalesceALTERA
    .{ .value = 5900, .cap = 5898, .ext = "", .core = 999 }, // CacheSizeALTERA
    .{ .value = 5901, .cap = 5898, .ext = "", .core = 999 }, // DontStaticallyCoalesceALTERA
    .{ .value = 5902, .cap = 5898, .ext = "", .core = 999 }, // PrefetchALTERA
    .{ .value = 5905, .cap = 5904, .ext = "", .core = 999 }, // StallEnableALTERA
    .{ .value = 5907, .cap = 5906, .ext = "", .core = 999 }, // FuseLoopsInFunctionALTERA
    .{ .value = 5909, .cap = 5908, .ext = "", .core = 999 }, // MathOpDSPModeALTERA
    .{ .value = 5914, .cap = 5910, .ext = "", .core = 999 }, // AliasScopeINTEL
    .{ .value = 5915, .cap = 5910, .ext = "", .core = 999 }, // NoAliasINTEL
    .{ .value = 5917, .cap = 5916, .ext = "", .core = 999 }, // InitiationIntervalALTERA
    .{ .value = 5918, .cap = 5916, .ext = "", .core = 999 }, // MaxConcurrencyALTERA
    .{ .value = 5919, .cap = 5916, .ext = "", .core = 999 }, // PipelineEnableALTERA
    .{ .value = 5921, .cap = 5920, .ext = "", .core = 999 }, // BufferLocationALTERA
    .{ .value = 5944, .cap = 5943, .ext = "", .core = 999 }, // IOPipeStorageALTERA
    .{ .value = 6080, .cap = 5821, .ext = "", .core = 999 }, // FunctionFloatingPointModeINTEL
    .{ .value = 6085, .cap = 5617, .ext = "", .core = 999 }, // SingleElementVectorINTEL
    .{ .value = 6087, .cap = 5617, .ext = "", .core = 999 }, // VectorComputeCallableFunctionINTEL
    .{ .value = 6140, .cap = 5617, .ext = "", .core = 999 }, // MediaBlockIOINTEL
    .{ .value = 6151, .cap = 6150, .ext = "", .core = 999 }, // StallFreeALTERA
    .{ .value = 6170, .cap = 6169, .ext = "", .core = 999 }, // FPMaxErrorDecorationINTEL
    .{ .value = 6172, .cap = 6171, .ext = "", .core = 999 }, // LatencyControlLabelALTERA
    .{ .value = 6173, .cap = 6171, .ext = "", .core = 999 }, // LatencyControlConstraintALTERA
    .{ .value = 6175, .cap = 6174, .ext = "", .core = 999 }, // ConduitKernelArgumentALTERA
    .{ .value = 6176, .cap = 6174, .ext = "", .core = 999 }, // RegisterMapKernelArgumentALTERA
    .{ .value = 6177, .cap = 6174, .ext = "", .core = 999 }, // MMHostInterfaceAddressWidthALTERA
    .{ .value = 6178, .cap = 6174, .ext = "", .core = 999 }, // MMHostInterfaceDataWidthALTERA
    .{ .value = 6179, .cap = 6174, .ext = "", .core = 999 }, // MMHostInterfaceLatencyALTERA
    .{ .value = 6180, .cap = 6174, .ext = "", .core = 999 }, // MMHostInterfaceReadWriteModeALTERA
    .{ .value = 6181, .cap = 6174, .ext = "", .core = 999 }, // MMHostInterfaceMaxBurstALTERA
    .{ .value = 6182, .cap = 6174, .ext = "", .core = 999 }, // MMHostInterfaceWaitRequestALTERA
    .{ .value = 6183, .cap = 6174, .ext = "", .core = 999 }, // StableKernelArgumentALTERA
    .{ .value = 6188, .cap = 6187, .ext = "", .core = 999 }, // HostAccessINTEL
    .{ .value = 6190, .cap = 6189, .ext = "", .core = 999 }, // InitModeALTERA
    .{ .value = 6191, .cap = 6189, .ext = "", .core = 999 }, // ImplementInRegisterMapALTERA
    .{ .value = 6247, .cap = 6245, .ext = "", .core = 999 }, // ConditionalINTEL
    .{ .value = 6442, .cap = 6441, .ext = "", .core = 999 }, // CacheControlLoadINTEL
    .{ .value = 6443, .cap = 6441, .ext = "", .core = 999 }, // CacheControlStoreINTEL
    .{ .value = 7040, .cap = 7041, .ext = "", .core = 999 }, // IntrinsicSAMSUNG
};

pub const execution_modes = [_]Need{
    .{ .value = 0, .cap = 2, .ext = "", .core = 100 }, // Invocations
    .{ .value = 1, .cap = 3, .ext = "", .core = 100 }, // SpacingEqual
    .{ .value = 2, .cap = 3, .ext = "", .core = 100 }, // SpacingFractionalEven
    .{ .value = 3, .cap = 3, .ext = "", .core = 100 }, // SpacingFractionalOdd
    .{ .value = 4, .cap = 3, .ext = "", .core = 100 }, // VertexOrderCw
    .{ .value = 5, .cap = 3, .ext = "", .core = 100 }, // VertexOrderCcw
    .{ .value = 6, .cap = 1, .ext = "", .core = 100 }, // PixelCenterInteger
    .{ .value = 7, .cap = 1, .ext = "", .core = 100 }, // OriginUpperLeft
    .{ .value = 8, .cap = 1, .ext = "", .core = 100 }, // OriginLowerLeft
    .{ .value = 9, .cap = 1, .ext = "", .core = 100 }, // EarlyFragmentTests
    .{ .value = 10, .cap = 3, .ext = "", .core = 100 }, // PointMode
    .{ .value = 11, .cap = 53, .ext = "", .core = 100 }, // Xfb
    .{ .value = 12, .cap = 1, .ext = "", .core = 100 }, // DepthReplacing
    .{ .value = 14, .cap = 1, .ext = "", .core = 100 }, // DepthGreater
    .{ .value = 15, .cap = 1, .ext = "", .core = 100 }, // DepthLess
    .{ .value = 16, .cap = 1, .ext = "", .core = 100 }, // DepthUnchanged
    .{ .value = 18, .cap = 6, .ext = "", .core = 100 }, // LocalSizeHint
    .{ .value = 19, .cap = 2, .ext = "", .core = 100 }, // InputPoints
    .{ .value = 20, .cap = 2, .ext = "", .core = 100 }, // InputLines
    .{ .value = 21, .cap = 2, .ext = "", .core = 100 }, // InputLinesAdjacency
    .{ .value = 22, .cap = 2, .ext = "", .core = 100 }, // Triangles
    .{ .value = 23, .cap = 2, .ext = "", .core = 100 }, // InputTrianglesAdjacency
    .{ .value = 24, .cap = 3, .ext = "", .core = 100 }, // Quads
    .{ .value = 25, .cap = 3, .ext = "", .core = 100 }, // Isolines
    .{ .value = 26, .cap = 2, .ext = "", .core = 100 }, // OutputVertices
    .{ .value = 27, .cap = 2, .ext = "", .core = 100 }, // OutputPoints
    .{ .value = 28, .cap = 2, .ext = "", .core = 100 }, // OutputLineStrip
    .{ .value = 29, .cap = 2, .ext = "", .core = 100 }, // OutputTriangleStrip
    .{ .value = 30, .cap = 6, .ext = "", .core = 100 }, // VecTypeHint
    .{ .value = 31, .cap = 6, .ext = "", .core = 100 }, // ContractionOff
    .{ .value = 33, .cap = 6, .ext = "", .core = 101 }, // Initializer
    .{ .value = 34, .cap = 6, .ext = "", .core = 101 }, // Finalizer
    .{ .value = 35, .cap = 58, .ext = "", .core = 101 }, // SubgroupSize
    .{ .value = 36, .cap = 58, .ext = "", .core = 101 }, // SubgroupsPerWorkgroup
    .{ .value = 37, .cap = 58, .ext = "", .core = 102 }, // SubgroupsPerWorkgroupId
    .{ .value = 39, .cap = 6, .ext = "", .core = 102 }, // LocalSizeHintId
    .{ .value = 4169, .cap = 4166, .ext = "", .core = 999 }, // NonCoherentColorAttachmentReadEXT
    .{ .value = 4170, .cap = 4167, .ext = "", .core = 999 }, // NonCoherentDepthAttachmentReadEXT
    .{ .value = 4171, .cap = 4168, .ext = "", .core = 999 }, // NonCoherentStencilAttachmentReadEXT
    .{ .value = 4421, .cap = 1, .ext = "SPV_KHR_subgroup_uniform_control_flow", .core = 999 }, // SubgroupUniformControlFlowKHR
    .{ .value = 4446, .cap = 4447, .ext = "SPV_KHR_post_depth_coverage", .core = 999 }, // PostDepthCoverage
    .{ .value = 4459, .cap = 4464, .ext = "SPV_KHR_float_controls", .core = 104 }, // DenormPreserve
    .{ .value = 4460, .cap = 4465, .ext = "SPV_KHR_float_controls", .core = 104 }, // DenormFlushToZero
    .{ .value = 4461, .cap = 4466, .ext = "SPV_KHR_float_controls", .core = 104 }, // SignedZeroInfNanPreserve
    .{ .value = 4462, .cap = 4467, .ext = "SPV_KHR_float_controls", .core = 104 }, // RoundingModeRTE
    .{ .value = 4463, .cap = 4468, .ext = "SPV_KHR_float_controls", .core = 104 }, // RoundingModeRTZ
    .{ .value = 4489, .cap = 4495, .ext = "", .core = 999 }, // NonCoherentTileAttachmentReadQCOM
    .{ .value = 4490, .cap = 4495, .ext = "", .core = 999 }, // TileShadingRateQCOM
    .{ .value = 5017, .cap = 1, .ext = "SPV_AMD_shader_early_and_late_fragment_tests", .core = 999 }, // EarlyAndLateFragmentTestsAMD
    .{ .value = 5027, .cap = 5013, .ext = "SPV_EXT_shader_stencil_export", .core = 999 }, // StencilRefReplacingEXT
    .{ .value = 5069, .cap = 5067, .ext = "", .core = 999 }, // CoalescingAMDX
    .{ .value = 5070, .cap = 5067, .ext = "", .core = 999 }, // IsApiEntryAMDX
    .{ .value = 5071, .cap = 5067, .ext = "", .core = 999 }, // MaxNodeRecursionAMDX
    .{ .value = 5072, .cap = 5067, .ext = "", .core = 999 }, // StaticNumWorkgroupsAMDX
    .{ .value = 5073, .cap = 5067, .ext = "", .core = 999 }, // ShaderIndexAMDX
    .{ .value = 5077, .cap = 5067, .ext = "", .core = 999 }, // MaxNumWorkgroupsAMDX
    .{ .value = 5079, .cap = 5013, .ext = "SPV_AMD_shader_early_and_late_fragment_tests", .core = 999 }, // StencilRefUnchangedFrontAMD
    .{ .value = 5080, .cap = 5013, .ext = "SPV_AMD_shader_early_and_late_fragment_tests", .core = 999 }, // StencilRefGreaterFrontAMD
    .{ .value = 5081, .cap = 5013, .ext = "SPV_AMD_shader_early_and_late_fragment_tests", .core = 999 }, // StencilRefLessFrontAMD
    .{ .value = 5082, .cap = 5013, .ext = "SPV_AMD_shader_early_and_late_fragment_tests", .core = 999 }, // StencilRefUnchangedBackAMD
    .{ .value = 5083, .cap = 5013, .ext = "SPV_AMD_shader_early_and_late_fragment_tests", .core = 999 }, // StencilRefGreaterBackAMD
    .{ .value = 5084, .cap = 5013, .ext = "SPV_AMD_shader_early_and_late_fragment_tests", .core = 999 }, // StencilRefLessBackAMD
    .{ .value = 5088, .cap = 5087, .ext = "", .core = 999 }, // QuadDerivativesKHR
    .{ .value = 5089, .cap = 5087, .ext = "", .core = 999 }, // RequireFullQuadsKHR
    .{ .value = 5102, .cap = 5067, .ext = "", .core = 999 }, // SharesInputWithAMDX
    .{ .value = 5157, .cap = 5156, .ext = "", .core = 999 }, // ArithmeticPoisonKHR
    .{ .value = 5269, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // OutputLinesEXT
    .{ .value = 5270, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // OutputPrimitivesEXT
    .{ .value = 5289, .cap = 5288, .ext = "SPV_NV_compute_shader_derivatives", .core = 999 }, // DerivativeGroupQuadsKHR
    .{ .value = 5290, .cap = 5350, .ext = "SPV_NV_compute_shader_derivatives", .core = 999 }, // DerivativeGroupLinearKHR
    .{ .value = 5298, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // OutputTrianglesEXT
    .{ .value = 5366, .cap = 5378, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // PixelInterlockOrderedEXT
    .{ .value = 5367, .cap = 5378, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // PixelInterlockUnorderedEXT
    .{ .value = 5368, .cap = 5363, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // SampleInterlockOrderedEXT
    .{ .value = 5369, .cap = 5363, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // SampleInterlockUnorderedEXT
    .{ .value = 5370, .cap = 5372, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // ShadingRateInterlockOrderedEXT
    .{ .value = 5371, .cap = 5372, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // ShadingRateInterlockUnorderedEXT
    .{ .value = 5427, .cap = 5426, .ext = "", .core = 999 }, // Shader64BitIndexingEXT
    .{ .value = 5618, .cap = 5617, .ext = "", .core = 999 }, // SharedLocalMemorySizeINTEL
    .{ .value = 5620, .cap = 5582, .ext = "", .core = 999 }, // RoundingModeRTPINTEL
    .{ .value = 5621, .cap = 5582, .ext = "", .core = 999 }, // RoundingModeRTNINTEL
    .{ .value = 5622, .cap = 5582, .ext = "", .core = 999 }, // FloatingPointModeALTINTEL
    .{ .value = 5623, .cap = 5582, .ext = "", .core = 999 }, // FloatingPointModeIEEEINTEL
    .{ .value = 5893, .cap = 5892, .ext = "SPV_INTEL_kernel_attributes", .core = 999 }, // MaxWorkgroupSizeINTEL
    .{ .value = 5894, .cap = 5892, .ext = "SPV_INTEL_kernel_attributes", .core = 999 }, // MaxWorkDimINTEL
    .{ .value = 5895, .cap = 5892, .ext = "SPV_INTEL_kernel_attributes", .core = 999 }, // NoGlobalOffsetINTEL
    .{ .value = 5896, .cap = 5897, .ext = "SPV_INTEL_kernel_attributes", .core = 999 }, // NumSIMDWorkitemsINTEL
    .{ .value = 5903, .cap = 5897, .ext = "", .core = 999 }, // SchedulerTargetFmaxMhzINTEL
    .{ .value = 6023, .cap = 1, .ext = "SPV_KHR_maximal_reconvergence", .core = 999 }, // MaximallyReconvergesKHR
    .{ .value = 6028, .cap = 6029, .ext = "", .core = 999 }, // FPFastMathDefault
    .{ .value = 6031, .cap = 6032, .ext = "", .core = 999 }, // OpacityMicromapIdKHR
    .{ .value = 6154, .cap = 5897, .ext = "", .core = 999 }, // StreamingInterfaceINTEL
    .{ .value = 6160, .cap = 6161, .ext = "", .core = 999 }, // RegisterMapInterfaceINTEL
    .{ .value = 6417, .cap = 5617, .ext = "", .core = 999 }, // NamedBarrierCountINTEL
    .{ .value = 6461, .cap = 6460, .ext = "", .core = 999 }, // MaximumRegistersINTEL
    .{ .value = 6462, .cap = 6460, .ext = "", .core = 999 }, // MaximumRegistersIdINTEL
    .{ .value = 6463, .cap = 6460, .ext = "", .core = 999 }, // NamedMaximumRegistersINTEL
};

pub fn get(opcode: u32) ?u32 {
    for (ops) |t| if (t[0] == opcode) return t[1];
    return null;
}

pub fn need(table: []const Need, value: u32) ?Need {
    for (table) |n| if (n.value == value) return n;
    return null;
}

/// Opcodes whose first operands are a result type and a result id.
const type_result_ops = [_]u16{
    1, 12, 41, 42, 43, 44, 45, 46, 48, 49, 50, 51, 52, 54, 55, 57,
    59, 60, 61, 65, 66, 67, 68, 69, 70, 77, 78, 79, 80, 81, 82, 83,
    84, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 100, 101,
    102, 103, 104, 105, 106, 107, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118,
    119, 120, 121, 122, 123, 124, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135,
    136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151,
    152, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168,
    169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184,
    185, 186, 187, 188, 189, 190, 191, 194, 195, 196, 197, 198, 199, 200, 201, 202,
    203, 204, 205, 207, 208, 209, 210, 211, 212, 213, 214, 215, 227, 229, 230, 231,
    232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 245, 259, 261, 262, 263,
    264, 265, 266, 267, 268, 269, 270, 271, 274, 275, 276, 277, 278, 279, 282, 283,
    284, 285, 286, 291, 292, 293, 294, 295, 296, 299, 300, 303, 304, 305, 306, 307,
    308, 309, 310, 311, 312, 313, 314, 315, 316, 318, 320, 321, 323, 324, 325, 326,
    328, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346, 347,
    348, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363,
    364, 365, 366, 400, 401, 402, 403, 4160, 4161, 4162, 4164, 4166, 4181, 4183, 4184, 4195,
    4418, 4419, 4420, 4421, 4422, 4423, 4424, 4425, 4427, 4428, 4429, 4430, 4431, 4432, 4433, 4434,
    4447, 4450, 4451, 4452, 4453, 4454, 4455, 4457, 4459, 4460, 4461, 4462, 4463, 4477, 4479, 4480,
    4481, 4482, 4483, 4497, 4500, 4501, 4502, 4503, 4540, 4541, 4542, 4545, 5000, 5001, 5002, 5003,
    5004, 5005, 5006, 5007, 5011, 5012, 5056, 5074, 5078, 5090, 5101, 5110, 5111, 5119, 5126, 5129,
    5147, 5148, 5158, 5159, 5252, 5253, 5254, 5255, 5257, 5258, 5265, 5267, 5268, 5269, 5270, 5271,
    5272, 5273, 5274, 5275, 5276, 5277, 5278, 5283, 5289, 5292, 5293, 5296, 5300, 5301, 5302, 5307,
    5308, 5320, 5322, 5323, 5324, 5325, 5326, 5327, 5328, 5329, 5330, 5331, 5332, 5333, 5334, 5340,
    5345, 5346, 5347, 5348, 5349, 5350, 5351, 5352, 5359, 5361, 5362, 5366, 5367, 5369, 5372, 5373,
    5374, 5375, 5376, 5377, 5378, 5379, 5381, 5382, 5384, 5390, 5391, 5392, 5393, 5394, 5395, 5396,
    5398, 5427, 5428, 5429, 5430, 5431, 5432, 5433, 5434, 5435, 5436, 5437, 5438, 5439, 5571, 5572,
    5573, 5574, 5575, 5577, 5580, 5585, 5586, 5587, 5588, 5589, 5590, 5591, 5592, 5593, 5594, 5595,
    5596, 5597, 5598, 5600, 5601, 5610, 5611, 5614, 5615, 5631, 5699, 5713, 5714, 5715, 5716, 5717,
    5718, 5719, 5720, 5721, 5722, 5723, 5724, 5725, 5726, 5727, 5728, 5729, 5730, 5731, 5732, 5733,
    5734, 5735, 5736, 5737, 5738, 5739, 5740, 5741, 5742, 5743, 5744, 5745, 5746, 5747, 5748, 5749,
    5750, 5751, 5752, 5753, 5754, 5755, 5756, 5757, 5758, 5759, 5760, 5761, 5762, 5763, 5764, 5765,
    5766, 5767, 5768, 5769, 5770, 5771, 5772, 5773, 5774, 5775, 5776, 5777, 5778, 5779, 5780, 5781,
    5782, 5783, 5784, 5785, 5786, 5787, 5788, 5789, 5790, 5791, 5792, 5793, 5794, 5795, 5796, 5797,
    5798, 5799, 5800, 5801, 5802, 5803, 5804, 5805, 5806, 5807, 5808, 5809, 5810, 5811, 5812, 5813,
    5814, 5815, 5816, 5818, 5819, 5840, 5841, 5842, 5843, 5846, 5847, 5848, 5849, 5850, 5851, 5852,
    5853, 5854, 5855, 5856, 5857, 5858, 5859, 5860, 5861, 5862, 5863, 5864, 5865, 5866, 5867, 5868,
    5869, 5870, 5871, 5872, 5873, 5874, 5875, 5876, 5877, 5878, 5879, 5880, 5881, 5882, 5923, 5924,
    5925, 5926, 5927, 5928, 5929, 5930, 5931, 5932, 5933, 5934, 5938, 5949, 6016, 6017, 6018, 6019,
    6020, 6021, 6022, 6023, 6024, 6025, 6026, 6027, 6028, 6029, 6030, 6031, 6032, 6035, 6116, 6117,
    6145, 6163, 6165, 6237, 6242, 6244, 6251, 6252, 6253, 6254, 6258, 6401, 6402, 6403, 6404, 6405,
    6406, 6407, 6408, 6426, 6428, 6529, 6530, 6531, 6916, 6917, 6918,
};

/// Opcodes with a result id but no result type.
const result_ops = [_]u16{
    7, 11, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    33, 34, 35, 36, 37, 38, 73, 248, 322, 327, 4163, 4190, 4417, 4456, 4472, 5076,
    5103, 5104, 5115, 5281, 5288, 5313, 5341, 5358, 5370, 5371, 5609, 5700, 5701, 5702, 5703, 5704,
    5705, 5706, 5707, 5708, 5709, 5710, 5711, 5712, 5911, 5912, 5913, 6086, 6199,
};

/// Where an instruction's result type and result id are (operand
/// indices), if it has them.
pub fn resultLayout(opcode: u32) struct { ty: ?u32, id: ?u32 } {
    const o: u16 = @intCast(opcode & 0xffff);
    if (std.sort.binarySearch(u16, &type_result_ops, o, order) != null) return .{ .ty = 0, .id = 1 };
    if (std.sort.binarySearch(u16, &result_ops, o, order) != null) return .{ .ty = null, .id = 0 };
    return .{ .ty = null, .id = null };
}

fn order(a: u16, b: u16) std.math.Order {
    return std.math.order(a, b);
}

/// Capabilities that need an extension (before the version that made
/// them core); KHR extensions preferred, as dxc does.
pub const capabilities = [_]Need{
    .{ .value = 18, .cap = 18, .ext = "SPV_AMD_shader_ballot", .core = 100 }, // Groups
    .{ .value = 4165, .cap = 4165, .ext = "SPV_ARM_core_builtins", .core = 999 }, // CoreBuiltinsARM
    .{ .value = 4166, .cap = 4166, .ext = "SPV_EXT_shader_tile_image", .core = 999 }, // TileImageColorReadAccessEXT
    .{ .value = 4167, .cap = 4167, .ext = "SPV_EXT_shader_tile_image", .core = 999 }, // TileImageDepthReadAccessEXT
    .{ .value = 4168, .cap = 4168, .ext = "SPV_EXT_shader_tile_image", .core = 999 }, // TileImageStencilReadAccessEXT
    .{ .value = 4174, .cap = 4174, .ext = "SPV_ARM_tensors", .core = 999 }, // TensorsARM
    .{ .value = 4175, .cap = 4175, .ext = "SPV_ARM_tensors", .core = 999 }, // StorageTensorArrayDynamicIndexingARM
    .{ .value = 4176, .cap = 4176, .ext = "SPV_ARM_tensors", .core = 999 }, // StorageTensorArrayNonUniformIndexingARM
    .{ .value = 4191, .cap = 4191, .ext = "SPV_ARM_graph", .core = 999 }, // GraphARM
    .{ .value = 4201, .cap = 4201, .ext = "SPV_ARM_cooperative_matrix_layouts", .core = 999 }, // CooperativeMatrixLayoutsARM
    .{ .value = 4212, .cap = 4212, .ext = "SPV_EXT_float8", .core = 999 }, // Float8EXT
    .{ .value = 4213, .cap = 4213, .ext = "SPV_EXT_float8", .core = 999 }, // Float8CooperativeMatrixEXT
    .{ .value = 4228, .cap = 4228, .ext = "SPV_EXT_ocp_microscaling_types", .core = 999 }, // Float6EXT
    .{ .value = 4229, .cap = 4229, .ext = "SPV_EXT_ocp_microscaling_types", .core = 999 }, // Float4EXT
    .{ .value = 4230, .cap = 4230, .ext = "SPV_EXT_ocp_microscaling_types", .core = 999 }, // Float8UnsignedE8M0EXT
    .{ .value = 4231, .cap = 4231, .ext = "SPV_EXT_ocp_microscaling_types", .core = 999 }, // MXInt8EXT
    .{ .value = 4232, .cap = 4232, .ext = "SPV_EXT_ocp_microscaling_types", .core = 999 }, // BitcastExtractEXT
    .{ .value = 4422, .cap = 4422, .ext = "SPV_KHR_fragment_shading_rate", .core = 999 }, // FragmentShadingRateKHR
    .{ .value = 4423, .cap = 4423, .ext = "SPV_KHR_shader_ballot", .core = 999 }, // SubgroupBallotKHR
    .{ .value = 4427, .cap = 4427, .ext = "SPV_KHR_shader_draw_parameters", .core = 103 }, // DrawParameters
    .{ .value = 4428, .cap = 4428, .ext = "SPV_KHR_workgroup_memory_explicit_layout", .core = 999 }, // WorkgroupMemoryExplicitLayoutKHR
    .{ .value = 4429, .cap = 4429, .ext = "SPV_KHR_workgroup_memory_explicit_layout", .core = 999 }, // WorkgroupMemoryExplicitLayout8BitAccessKHR
    .{ .value = 4430, .cap = 4430, .ext = "SPV_KHR_workgroup_memory_explicit_layout", .core = 999 }, // WorkgroupMemoryExplicitLayout16BitAccessKHR
    .{ .value = 4431, .cap = 4431, .ext = "SPV_KHR_subgroup_vote", .core = 999 }, // SubgroupVoteKHR
    .{ .value = 4433, .cap = 4433, .ext = "SPV_KHR_16bit_storage", .core = 103 }, // StorageBuffer16BitAccess
    .{ .value = 4434, .cap = 4434, .ext = "SPV_KHR_16bit_storage", .core = 103 }, // UniformAndStorageBuffer16BitAccess
    .{ .value = 4435, .cap = 4435, .ext = "SPV_KHR_16bit_storage", .core = 103 }, // StoragePushConstant16
    .{ .value = 4436, .cap = 4436, .ext = "SPV_KHR_16bit_storage", .core = 103 }, // StorageInputOutput16
    .{ .value = 4437, .cap = 4437, .ext = "SPV_KHR_device_group", .core = 103 }, // DeviceGroup
    .{ .value = 4439, .cap = 4439, .ext = "SPV_KHR_multiview", .core = 103 }, // MultiView
    .{ .value = 4441, .cap = 4441, .ext = "SPV_KHR_variable_pointers", .core = 103 }, // VariablePointersStorageBuffer
    .{ .value = 4442, .cap = 4442, .ext = "SPV_KHR_variable_pointers", .core = 103 }, // VariablePointers
    .{ .value = 4445, .cap = 4445, .ext = "SPV_KHR_shader_atomic_counter_ops", .core = 999 }, // AtomicStorageOps
    .{ .value = 4447, .cap = 4447, .ext = "SPV_KHR_post_depth_coverage", .core = 999 }, // SampleMaskPostDepthCoverage
    .{ .value = 4448, .cap = 4448, .ext = "SPV_KHR_8bit_storage", .core = 105 }, // StorageBuffer8BitAccess
    .{ .value = 4449, .cap = 4449, .ext = "SPV_KHR_8bit_storage", .core = 105 }, // UniformAndStorageBuffer8BitAccess
    .{ .value = 4450, .cap = 4450, .ext = "SPV_KHR_8bit_storage", .core = 105 }, // StoragePushConstant8
    .{ .value = 4464, .cap = 4464, .ext = "SPV_KHR_float_controls", .core = 104 }, // DenormPreserve
    .{ .value = 4465, .cap = 4465, .ext = "SPV_KHR_float_controls", .core = 104 }, // DenormFlushToZero
    .{ .value = 4466, .cap = 4466, .ext = "SPV_KHR_float_controls", .core = 104 }, // SignedZeroInfNanPreserve
    .{ .value = 4467, .cap = 4467, .ext = "SPV_KHR_float_controls", .core = 104 }, // RoundingModeRTE
    .{ .value = 4468, .cap = 4468, .ext = "SPV_KHR_float_controls", .core = 104 }, // RoundingModeRTZ
    .{ .value = 4471, .cap = 4471, .ext = "SPV_KHR_ray_query", .core = 999 }, // RayQueryProvisionalKHR
    .{ .value = 4472, .cap = 4472, .ext = "SPV_KHR_ray_query", .core = 999 }, // RayQueryKHR
    .{ .value = 4473, .cap = 4473, .ext = "SPV_KHR_untyped_pointers", .core = 999 }, // UntypedPointersKHR
    .{ .value = 4478, .cap = 4478, .ext = "SPV_KHR_ray_query", .core = 999 }, // RayTraversalPrimitiveCullingKHR
    .{ .value = 4479, .cap = 4479, .ext = "SPV_KHR_ray_tracing", .core = 999 }, // RayTracingKHR
    .{ .value = 4484, .cap = 4484, .ext = "SPV_QCOM_image_processing", .core = 999 }, // TextureSampleWeightedQCOM
    .{ .value = 4485, .cap = 4485, .ext = "SPV_QCOM_image_processing", .core = 999 }, // TextureBoxFilterQCOM
    .{ .value = 4486, .cap = 4486, .ext = "SPV_QCOM_image_processing", .core = 999 }, // TextureBlockMatchQCOM
    .{ .value = 4495, .cap = 4495, .ext = "SPV_QCOM_tile_shading", .core = 999 }, // TileShadingQCOM
    .{ .value = 4496, .cap = 4496, .ext = "SPV_QCOM_cooperative_matrix_conversion", .core = 999 }, // CooperativeMatrixConversionQCOM
    .{ .value = 4498, .cap = 4498, .ext = "SPV_QCOM_image_processing2", .core = 999 }, // TextureBlockMatch2QCOM
    .{ .value = 4539, .cap = 4539, .ext = "SPV_QCOM_multiple_wait_queues", .core = 999 }, // MultipleWaitQueuesQCOM
    .{ .value = 4543, .cap = 4543, .ext = "SPV_QCOM_image_processing3", .core = 999 }, // ImageGatherLinearQCOM
    .{ .value = 4544, .cap = 4544, .ext = "SPV_QCOM_image_processing3", .core = 999 }, // ImageGatherExtendedModesQCOM
    .{ .value = 5008, .cap = 5008, .ext = "SPV_AMD_gpu_shader_half_float_fetch", .core = 999 }, // Float16ImageAMD
    .{ .value = 5009, .cap = 5009, .ext = "SPV_AMD_texture_gather_bias_lod", .core = 999 }, // ImageGatherBiasLodAMD
    .{ .value = 5010, .cap = 5010, .ext = "SPV_AMD_shader_fragment_mask", .core = 999 }, // FragmentMaskAMD
    .{ .value = 5013, .cap = 5013, .ext = "SPV_EXT_shader_stencil_export", .core = 999 }, // StencilExportEXT
    .{ .value = 5015, .cap = 5015, .ext = "SPV_AMD_shader_image_load_store_lod", .core = 999 }, // ImageReadWriteLodAMD
    .{ .value = 5016, .cap = 5016, .ext = "SPV_EXT_shader_image_int64", .core = 999 }, // Int64ImageEXT
    .{ .value = 5055, .cap = 5055, .ext = "SPV_KHR_shader_clock", .core = 999 }, // ShaderClockKHR
    .{ .value = 5067, .cap = 5067, .ext = "SPV_AMDX_shader_enqueue", .core = 999 }, // ShaderEnqueueAMDX
    .{ .value = 5087, .cap = 5087, .ext = "SPV_KHR_quad_control", .core = 999 }, // QuadControlKHR
    .{ .value = 5112, .cap = 5112, .ext = "SPV_INTEL_int4", .core = 999 }, // Int4TypeINTEL
    .{ .value = 5114, .cap = 5114, .ext = "SPV_INTEL_int4", .core = 999 }, // Int4CooperativeMatrixINTEL
    .{ .value = 5116, .cap = 5116, .ext = "SPV_KHR_bfloat16", .core = 999 }, // BFloat16TypeKHR
    .{ .value = 5117, .cap = 5117, .ext = "SPV_KHR_bfloat16", .core = 999 }, // BFloat16DotProductKHR
    .{ .value = 5118, .cap = 5118, .ext = "SPV_KHR_bfloat16", .core = 999 }, // BFloat16CooperativeMatrixKHR
    .{ .value = 5120, .cap = 5120, .ext = "SPV_KHR_abort", .core = 999 }, // AbortKHR
    .{ .value = 5128, .cap = 5128, .ext = "SPV_EXT_descriptor_heap", .core = 999 }, // DescriptorHeapEXT
    .{ .value = 5146, .cap = 5146, .ext = "SPV_KHR_constant_data", .core = 999 }, // ConstantDataKHR
    .{ .value = 5156, .cap = 5156, .ext = "SPV_KHR_poison_freeze", .core = 999 }, // PoisonFreezeKHR
    .{ .value = 5181, .cap = 5181, .ext = "SPV_AMD_weak_linkage", .core = 999 }, // WeakLinkageAMD
    .{ .value = 5249, .cap = 5249, .ext = "SPV_NV_sample_mask_override_coverage", .core = 999 }, // SampleMaskOverrideCoverageNV
    .{ .value = 5251, .cap = 5251, .ext = "SPV_NV_geometry_shader_passthrough", .core = 999 }, // GeometryShaderPassthroughNV
    .{ .value = 5254, .cap = 5254, .ext = "SPV_EXT_shader_viewport_index_layer", .core = 999 }, // ShaderViewportIndexLayerEXT
    .{ .value = 5255, .cap = 5255, .ext = "SPV_NV_viewport_array2", .core = 999 }, // ShaderViewportMaskNV
    .{ .value = 5259, .cap = 5259, .ext = "SPV_NV_stereo_view_rendering", .core = 999 }, // ShaderStereoViewNV
    .{ .value = 5260, .cap = 5260, .ext = "SPV_NVX_multiview_per_view_attributes", .core = 999 }, // PerViewAttributesNV
    .{ .value = 5265, .cap = 5265, .ext = "SPV_EXT_fragment_fully_covered", .core = 999 }, // FragmentFullyCoveredEXT
    .{ .value = 5266, .cap = 5266, .ext = "SPV_NV_mesh_shader", .core = 999 }, // MeshShadingNV
    .{ .value = 5282, .cap = 5282, .ext = "SPV_NV_shader_image_footprint", .core = 999 }, // ImageFootprintNV
    .{ .value = 5283, .cap = 5283, .ext = "SPV_EXT_mesh_shader", .core = 999 }, // MeshShadingEXT
    .{ .value = 5284, .cap = 5284, .ext = "SPV_KHR_fragment_shader_barycentric", .core = 999 }, // FragmentBarycentricKHR
    .{ .value = 5288, .cap = 5288, .ext = "SPV_KHR_compute_shader_derivatives", .core = 999 }, // ComputeDerivativeGroupQuadsKHR
    .{ .value = 5291, .cap = 5291, .ext = "SPV_EXT_fragment_invocation_density", .core = 999 }, // FragmentDensityEXT
    .{ .value = 5297, .cap = 5297, .ext = "SPV_NV_shader_subgroup_partitioned", .core = 999 }, // GroupNonUniformPartitionedEXT
    .{ .value = 5301, .cap = 5301, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // ShaderNonUniform
    .{ .value = 5302, .cap = 5302, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // RuntimeDescriptorArray
    .{ .value = 5303, .cap = 5303, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // InputAttachmentArrayDynamicIndexing
    .{ .value = 5304, .cap = 5304, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // UniformTexelBufferArrayDynamicIndexing
    .{ .value = 5305, .cap = 5305, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // StorageTexelBufferArrayDynamicIndexing
    .{ .value = 5306, .cap = 5306, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // UniformBufferArrayNonUniformIndexing
    .{ .value = 5307, .cap = 5307, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // SampledImageArrayNonUniformIndexing
    .{ .value = 5308, .cap = 5308, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // StorageBufferArrayNonUniformIndexing
    .{ .value = 5309, .cap = 5309, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // StorageImageArrayNonUniformIndexing
    .{ .value = 5310, .cap = 5310, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // InputAttachmentArrayNonUniformIndexing
    .{ .value = 5311, .cap = 5311, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // UniformTexelBufferArrayNonUniformIndexing
    .{ .value = 5312, .cap = 5312, .ext = "SPV_EXT_descriptor_indexing", .core = 105 }, // StorageTexelBufferArrayNonUniformIndexing
    .{ .value = 5336, .cap = 5336, .ext = "SPV_KHR_ray_tracing_position_fetch", .core = 999 }, // RayTracingPositionFetchKHR
    .{ .value = 5340, .cap = 5340, .ext = "SPV_NV_ray_tracing", .core = 999 }, // RayTracingNV
    .{ .value = 5341, .cap = 5341, .ext = "SPV_NV_ray_tracing_motion_blur", .core = 999 }, // RayTracingMotionBlurNV
    .{ .value = 5345, .cap = 5345, .ext = "SPV_KHR_vulkan_memory_model", .core = 105 }, // VulkanMemoryModel
    .{ .value = 5346, .cap = 5346, .ext = "SPV_KHR_vulkan_memory_model", .core = 105 }, // VulkanMemoryModelDeviceScope
    .{ .value = 5347, .cap = 5347, .ext = "SPV_KHR_physical_storage_buffer", .core = 105 }, // PhysicalStorageBufferAddresses
    .{ .value = 5350, .cap = 5350, .ext = "SPV_KHR_compute_shader_derivatives", .core = 999 }, // ComputeDerivativeGroupLinearKHR
    .{ .value = 5353, .cap = 5353, .ext = "SPV_KHR_ray_tracing", .core = 999 }, // RayTracingProvisionalKHR
    .{ .value = 5357, .cap = 5357, .ext = "SPV_NV_cooperative_matrix", .core = 999 }, // CooperativeMatrixNV
    .{ .value = 5363, .cap = 5363, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // FragmentShaderSampleInterlockEXT
    .{ .value = 5372, .cap = 5372, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // FragmentShaderShadingRateInterlockEXT
    .{ .value = 5373, .cap = 5373, .ext = "SPV_NV_shader_sm_builtins", .core = 999 }, // ShaderSMBuiltinsNV
    .{ .value = 5378, .cap = 5378, .ext = "SPV_EXT_fragment_shader_interlock", .core = 999 }, // FragmentShaderPixelInterlockEXT
    .{ .value = 5379, .cap = 5379, .ext = "SPV_EXT_demote_to_helper_invocation", .core = 106 }, // DemoteToHelperInvocation
    .{ .value = 5380, .cap = 5380, .ext = "SPV_NV_displacement_micromap", .core = 999 }, // DisplacementMicromapNV
    .{ .value = 5381, .cap = 5381, .ext = "SPV_KHR_opacity_micromap", .core = 999 }, // RayTracingOpacityMicromapKHR
    .{ .value = 5383, .cap = 5383, .ext = "SPV_NV_shader_invocation_reorder", .core = 999 }, // ShaderInvocationReorderNV
    .{ .value = 5388, .cap = 5388, .ext = "SPV_EXT_shader_invocation_reorder", .core = 999 }, // ShaderInvocationReorderEXT
    .{ .value = 5390, .cap = 5390, .ext = "SPV_NV_bindless_texture", .core = 999 }, // BindlessTextureNV
    .{ .value = 5391, .cap = 5391, .ext = "SPV_KHR_ray_tracing_position_fetch", .core = 999 }, // RayQueryPositionFetchKHR
    .{ .value = 5394, .cap = 5394, .ext = "SPV_NV_cooperative_vector", .core = 999 }, // CooperativeVectorNV
    .{ .value = 5404, .cap = 5404, .ext = "SPV_NV_shader_atomic_fp16_vector", .core = 999 }, // AtomicFloat16VectorNV
    .{ .value = 5409, .cap = 5409, .ext = "SPV_NV_displacement_micromap", .core = 999 }, // RayTracingDisplacementMicromapNV
    .{ .value = 5414, .cap = 5414, .ext = "SPV_NV_raw_access_chains", .core = 999 }, // RawAccessChainsNV
    .{ .value = 5418, .cap = 5418, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // RayTracingSpheresGeometryNV
    .{ .value = 5419, .cap = 5419, .ext = "SPV_NV_linear_swept_spheres", .core = 999 }, // RayTracingLinearSweptSpheresGeometryNV
    .{ .value = 5423, .cap = 5423, .ext = "SPV_NV_push_constant_bank", .core = 999 }, // PushConstantBanksNV
    .{ .value = 5425, .cap = 5425, .ext = "SPV_EXT_long_vector", .core = 999 }, // LongVectorEXT
    .{ .value = 5426, .cap = 5426, .ext = "SPV_EXT_shader_64bit_indexing", .core = 999 }, // Shader64BitIndexingEXT
    .{ .value = 5430, .cap = 5430, .ext = "SPV_NV_cooperative_matrix2", .core = 999 }, // CooperativeMatrixReductionsNV
    .{ .value = 5431, .cap = 5431, .ext = "SPV_NV_cooperative_matrix2", .core = 999 }, // CooperativeMatrixConversionsNV
    .{ .value = 5432, .cap = 5432, .ext = "SPV_NV_cooperative_matrix2", .core = 999 }, // CooperativeMatrixPerElementOperationsNV
    .{ .value = 5433, .cap = 5433, .ext = "SPV_NV_cooperative_matrix2", .core = 999 }, // CooperativeMatrixTensorAddressingNV
    .{ .value = 5434, .cap = 5434, .ext = "SPV_NV_cooperative_matrix2", .core = 999 }, // CooperativeMatrixBlockLoadsNV
    .{ .value = 5435, .cap = 5435, .ext = "SPV_NV_cooperative_vector", .core = 999 }, // CooperativeVectorTrainingNV
    .{ .value = 5437, .cap = 5437, .ext = "SPV_NV_cluster_acceleration_structure", .core = 999 }, // RayTracingClusterAccelerationStructureNV
    .{ .value = 5439, .cap = 5439, .ext = "SPV_NV_tensor_addressing", .core = 999 }, // TensorAddressingNV
    .{ .value = 5447, .cap = 5447, .ext = "SPV_NV_cooperative_matrix_decode_vector", .core = 999 }, // CooperativeMatrixDecodeVectorNV
    .{ .value = 5568, .cap = 5568, .ext = "SPV_INTEL_subgroups", .core = 999 }, // SubgroupShuffleINTEL
    .{ .value = 5569, .cap = 5569, .ext = "SPV_INTEL_subgroups", .core = 999 }, // SubgroupBufferBlockIOINTEL
    .{ .value = 5570, .cap = 5570, .ext = "SPV_INTEL_subgroups", .core = 999 }, // SubgroupImageBlockIOINTEL
    .{ .value = 5579, .cap = 5579, .ext = "SPV_INTEL_media_block_io", .core = 999 }, // SubgroupImageMediaBlockIOINTEL
    .{ .value = 5582, .cap = 5582, .ext = "SPV_INTEL_float_controls2", .core = 999 }, // RoundToInfinityINTEL
    .{ .value = 5583, .cap = 5583, .ext = "SPV_INTEL_float_controls2", .core = 999 }, // FloatingPointModeINTEL
    .{ .value = 5584, .cap = 5584, .ext = "SPV_INTEL_shader_integer_functions2", .core = 999 }, // IntegerFunctions2INTEL
    .{ .value = 5603, .cap = 5603, .ext = "SPV_INTEL_function_pointers", .core = 999 }, // FunctionPointersINTEL
    .{ .value = 5604, .cap = 5604, .ext = "SPV_INTEL_function_pointers", .core = 999 }, // IndirectReferencesINTEL
    .{ .value = 5606, .cap = 5606, .ext = "SPV_INTEL_inline_assembly", .core = 999 }, // AsmINTEL
    .{ .value = 5612, .cap = 5612, .ext = "SPV_EXT_shader_atomic_float_min_max", .core = 999 }, // AtomicFloat32MinMaxEXT
    .{ .value = 5613, .cap = 5613, .ext = "SPV_EXT_shader_atomic_float_min_max", .core = 999 }, // AtomicFloat64MinMaxEXT
    .{ .value = 5616, .cap = 5616, .ext = "SPV_EXT_shader_atomic_float_min_max", .core = 999 }, // AtomicFloat16MinMaxEXT
    .{ .value = 5617, .cap = 5617, .ext = "SPV_INTEL_vector_compute", .core = 999 }, // VectorComputeINTEL
    .{ .value = 5619, .cap = 5619, .ext = "SPV_INTEL_vector_compute", .core = 999 }, // VectorAnyINTEL
    .{ .value = 5629, .cap = 5629, .ext = "SPV_KHR_expect_assume", .core = 999 }, // ExpectAssumeKHR
    .{ .value = 5696, .cap = 5696, .ext = "SPV_INTEL_device_side_avc_motion_estimation", .core = 999 }, // SubgroupAvcMotionEstimationINTEL
    .{ .value = 5697, .cap = 5697, .ext = "SPV_INTEL_device_side_avc_motion_estimation", .core = 999 }, // SubgroupAvcMotionEstimationIntraINTEL
    .{ .value = 5698, .cap = 5698, .ext = "SPV_INTEL_device_side_avc_motion_estimation", .core = 999 }, // SubgroupAvcMotionEstimationChromaINTEL
    .{ .value = 5817, .cap = 5817, .ext = "SPV_INTEL_variable_length_array", .core = 999 }, // VariableLengthArrayINTEL
    .{ .value = 5821, .cap = 5821, .ext = "SPV_INTEL_float_controls2", .core = 999 }, // FunctionFloatControlINTEL
    .{ .value = 5824, .cap = 5824, .ext = "SPV_ALTERA_fpga_memory_attributes", .core = 999 }, // FPGAMemoryAttributesALTERA
    .{ .value = 5837, .cap = 5837, .ext = "SPV_INTEL_fp_fast_math_mode", .core = 999 }, // FPFastMathModeINTEL
    .{ .value = 5844, .cap = 5844, .ext = "SPV_ALTERA_arbitrary_precision_integers", .core = 999 }, // ArbitraryPrecisionIntegersALTERA
    .{ .value = 5845, .cap = 5845, .ext = "SPV_ALTERA_arbitrary_precision_floating_point", .core = 999 }, // ArbitraryPrecisionFloatingPointALTERA
    .{ .value = 5886, .cap = 5886, .ext = "SPV_INTEL_unstructured_loop_controls", .core = 999 }, // UnstructuredLoopControlsINTEL
    .{ .value = 5888, .cap = 5888, .ext = "SPV_ALTERA_fpga_loop_controls", .core = 999 }, // FPGALoopControlsALTERA
    .{ .value = 5892, .cap = 5892, .ext = "SPV_INTEL_kernel_attributes", .core = 999 }, // KernelAttributesINTEL
    .{ .value = 5897, .cap = 5897, .ext = "SPV_INTEL_kernel_attributes", .core = 999 }, // FPGAKernelAttributesINTEL
    .{ .value = 5898, .cap = 5898, .ext = "SPV_ALTERA_fpga_memory_accesses", .core = 999 }, // FPGAMemoryAccessesALTERA
    .{ .value = 5904, .cap = 5904, .ext = "SPV_ALTERA_fpga_cluster_attributes", .core = 999 }, // FPGAClusterAttributesALTERA
    .{ .value = 5906, .cap = 5906, .ext = "SPV_ALTERA_loop_fuse", .core = 999 }, // LoopFuseALTERA
    .{ .value = 5908, .cap = 5908, .ext = "SPV_ALTERA_fpga_dsp_control", .core = 999 }, // FPGADSPControlALTERA
    .{ .value = 5910, .cap = 5910, .ext = "SPV_INTEL_memory_access_aliasing", .core = 999 }, // MemoryAccessAliasingINTEL
    .{ .value = 5916, .cap = 5916, .ext = "SPV_ALTERA_fpga_invocation_pipelining_attributes", .core = 999 }, // FPGAInvocationPipeliningAttributesALTERA
    .{ .value = 5920, .cap = 5920, .ext = "SPV_ALTERA_fpga_buffer_location", .core = 999 }, // FPGABufferLocationALTERA
    .{ .value = 5922, .cap = 5922, .ext = "SPV_ALTERA_arbitrary_precision_fixed_point", .core = 999 }, // ArbitraryPrecisionFixedPointALTERA
    .{ .value = 5935, .cap = 5935, .ext = "SPV_ALTERA_usm_storage_classes", .core = 999 }, // USMStorageClassesALTERA
    .{ .value = 5939, .cap = 5939, .ext = "SPV_ALTERA_runtime_aligned", .core = 999 }, // RuntimeAlignedAttributeALTERA
    .{ .value = 5943, .cap = 5943, .ext = "SPV_ALTERA_io_pipes", .core = 999 }, // IOPipesALTERA
    .{ .value = 5945, .cap = 5945, .ext = "SPV_ALTERA_blocking_pipes", .core = 999 }, // BlockingPipesALTERA
    .{ .value = 5948, .cap = 5948, .ext = "SPV_ALTERA_fpga_reg", .core = 999 }, // FPGARegALTERA
    .{ .value = 6016, .cap = 6016, .ext = "SPV_KHR_integer_dot_product", .core = 106 }, // DotProductInputAll
    .{ .value = 6017, .cap = 6017, .ext = "SPV_KHR_integer_dot_product", .core = 106 }, // DotProductInput4x8Bit
    .{ .value = 6018, .cap = 6018, .ext = "SPV_KHR_integer_dot_product", .core = 106 }, // DotProductInput4x8BitPacked
    .{ .value = 6019, .cap = 6019, .ext = "SPV_KHR_integer_dot_product", .core = 106 }, // DotProduct
    .{ .value = 6020, .cap = 6020, .ext = "SPV_KHR_ray_cull_mask", .core = 999 }, // RayCullMaskKHR
    .{ .value = 6022, .cap = 6022, .ext = "SPV_KHR_cooperative_matrix", .core = 999 }, // CooperativeMatrixKHR
    .{ .value = 6024, .cap = 6024, .ext = "SPV_EXT_replicated_composites", .core = 999 }, // ReplicatedCompositesEXT
    .{ .value = 6025, .cap = 6025, .ext = "SPV_KHR_bit_instructions", .core = 999 }, // BitInstructions
    .{ .value = 6026, .cap = 6026, .ext = "SPV_KHR_subgroup_rotate", .core = 999 }, // GroupNonUniformRotateKHR
    .{ .value = 6029, .cap = 6029, .ext = "SPV_KHR_float_controls2", .core = 999 }, // FloatControls2
    .{ .value = 6030, .cap = 6030, .ext = "SPV_KHR_fma", .core = 999 }, // FMAKHR
    .{ .value = 6032, .cap = 6032, .ext = "SPV_KHR_opacity_micromap", .core = 999 }, // RayTracingOpacityMicromapExecutionModeKHR
    .{ .value = 6033, .cap = 6033, .ext = "SPV_EXT_shader_atomic_float_add", .core = 999 }, // AtomicFloat32AddEXT
    .{ .value = 6034, .cap = 6034, .ext = "SPV_EXT_shader_atomic_float_add", .core = 999 }, // AtomicFloat64AddEXT
    .{ .value = 6089, .cap = 6089, .ext = "SPV_INTEL_long_composites", .core = 999 }, // LongCompositesINTEL
    .{ .value = 6094, .cap = 6094, .ext = "SPV_EXT_optnone", .core = 999 }, // OptNoneEXT
    .{ .value = 6095, .cap = 6095, .ext = "SPV_EXT_shader_atomic_float16_add", .core = 999 }, // AtomicFloat16AddEXT
    .{ .value = 6114, .cap = 6114, .ext = "SPV_INTEL_debug_module", .core = 999 }, // DebugInfoModuleINTEL
    .{ .value = 6115, .cap = 6115, .ext = "SPV_INTEL_bfloat16_conversion", .core = 999 }, // BFloat16ConversionINTEL
    .{ .value = 6141, .cap = 6141, .ext = "SPV_EXT_split_barrier", .core = 999 }, // SplitBarrierEXT
    .{ .value = 6144, .cap = 6144, .ext = "SPV_EXT_arithmetic_fence", .core = 999 }, // ArithmeticFenceEXT
    .{ .value = 6150, .cap = 6150, .ext = "SPV_ALTERA_fpga_cluster_attributes", .core = 999 }, // FPGAClusterAttributesV2ALTERA
    .{ .value = 6161, .cap = 6161, .ext = "SPV_INTEL_kernel_attributes", .core = 999 }, // FPGAKernelAttributesv2INTEL
    .{ .value = 6162, .cap = 6162, .ext = "SPV_ALTERA_task_sequence", .core = 999 }, // TaskSequenceALTERA
    .{ .value = 6169, .cap = 6169, .ext = "SPV_INTEL_fp_max_error", .core = 999 }, // FPMaxErrorINTEL
    .{ .value = 6171, .cap = 6171, .ext = "SPV_ALTERA_fpga_latency_control", .core = 999 }, // FPGALatencyControlALTERA
    .{ .value = 6174, .cap = 6174, .ext = "SPV_ALTERA_fpga_argument_interfaces", .core = 999 }, // FPGAArgumentInterfacesALTERA
    .{ .value = 6187, .cap = 6187, .ext = "SPV_INTEL_global_variable_host_access", .core = 999 }, // GlobalVariableHostAccessINTEL
    .{ .value = 6189, .cap = 6189, .ext = "SPV_ALTERA_global_variable_fpga_decorations", .core = 999 }, // GlobalVariableFPGADecorationsALTERA
    .{ .value = 6220, .cap = 6220, .ext = "SPV_INTEL_subgroup_buffer_prefetch", .core = 999 }, // SubgroupBufferPrefetchINTEL
    .{ .value = 6228, .cap = 6228, .ext = "SPV_INTEL_2d_block_io", .core = 999 }, // Subgroup2DBlockIOINTEL
    .{ .value = 6229, .cap = 6229, .ext = "SPV_INTEL_2d_block_io", .core = 999 }, // Subgroup2DBlockTransformINTEL
    .{ .value = 6230, .cap = 6230, .ext = "SPV_INTEL_2d_block_io", .core = 999 }, // Subgroup2DBlockTransposeINTEL
    .{ .value = 6236, .cap = 6236, .ext = "SPV_INTEL_subgroup_matrix_multiply_accumulate", .core = 999 }, // SubgroupMatrixMultiplyAccumulateINTEL
    .{ .value = 6241, .cap = 6241, .ext = "SPV_INTEL_ternary_bitwise_function", .core = 999 }, // TernaryBitwiseFunctionINTEL
    .{ .value = 6243, .cap = 6243, .ext = "SPV_INTEL_variable_length_array", .core = 999 }, // UntypedVariableLengthArrayINTEL
    .{ .value = 6245, .cap = 6245, .ext = "SPV_INTEL_function_variants", .core = 999 }, // SpecConditionalINTEL
    .{ .value = 6246, .cap = 6246, .ext = "SPV_INTEL_function_variants", .core = 999 }, // FunctionVariantsINTEL
    .{ .value = 6257, .cap = 6257, .ext = "SPV_INTEL_predicated_io", .core = 999 }, // PredicatedIOINTEL
    .{ .value = 6265, .cap = 6265, .ext = "SPV_INTEL_rounded_divide_sqrt", .core = 999 }, // RoundedDivideSqrtINTEL
    .{ .value = 6400, .cap = 6400, .ext = "SPV_KHR_uniform_group_instructions", .core = 999 }, // GroupUniformArithmeticKHR
    .{ .value = 6425, .cap = 6425, .ext = "SPV_INTEL_tensor_float32_conversion", .core = 999 }, // TensorFloat32RoundingINTEL
    .{ .value = 6427, .cap = 6427, .ext = "SPV_INTEL_masked_gather_scatter", .core = 999 }, // MaskedGatherScatterINTEL
    .{ .value = 6441, .cap = 6441, .ext = "SPV_INTEL_cache_controls", .core = 999 }, // CacheControlsINTEL
    .{ .value = 6460, .cap = 6460, .ext = "SPV_INTEL_maximum_registers", .core = 999 }, // RegisterLimitsINTEL
    .{ .value = 6528, .cap = 6528, .ext = "SPV_INTEL_bindless_images", .core = 999 }, // BindlessImagesINTEL
    .{ .value = 6912, .cap = 6912, .ext = "SPV_VALVE_mixed_float_dot_product", .core = 999 }, // DotProductFloat16AccFloat32VALVE
    .{ .value = 6913, .cap = 6913, .ext = "SPV_VALVE_mixed_float_dot_product", .core = 999 }, // DotProductFloat16AccFloat16VALVE
    .{ .value = 6914, .cap = 6914, .ext = "SPV_VALVE_mixed_float_dot_product", .core = 999 }, // DotProductBFloat16AccVALVE
    .{ .value = 6915, .cap = 6915, .ext = "SPV_VALVE_mixed_float_dot_product", .core = 999 }, // DotProductFloat8AccFloat32VALVE
    .{ .value = 7041, .cap = 7041, .ext = "SPV_SAMSUNG_intrinsic", .core = 999 }, // IntrinsicSAMSUNG
};
