//! What SPIR-V instructions and enumerants need (the first capability /
//! extension the grammar lists), for inline SPIR-V. Generated from
//! SPIRV-Headers' spirv.core.grammar.json in the DXC tree
//! (external/SPIRV-Headers).

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
