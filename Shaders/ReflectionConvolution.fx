#include "Common.fh"
#include "SbmReflectionMark.fh"

#define KernelRadius 3
#define ThreadGroupSize 16

groupshared float3 samples[ThreadGroupSize][ThreadGroupSize + 2 * KernelRadius];

float3 BlurPixel(in uint2 pixel)
{
	const float Weights[2 * KernelRadius + 1] =
	{
		0.001f, 0.028f, 0.233f, 0.474f, 0.233f, 0.028f, 0.001f
	};

	float3 result = broadcast3(0.0f);

	UNROLL_LOOP
	for (int i = 0; i <= 2 * KernelRadius; ++i)
		result += Weights[i] * samples[pixel.x][pixel.y + i];

	return result;
}

#if defined(HGAUSS)

	DefineTexture2D(CS, Input, 0, FLOAT3_FMT);
	DefineRWTexture2D(Output, 0, FLOAT3_FMT, float_r11g11b10, NON_COHERENT);

	BEGIN_CBUFFER(MainParams, 0)
		DECL_UNIFORM(float2, InputTexelSize)
	END_CBUFFER

	// SBM: the vanilla linear sample sits on a texel corner, so it averages a 2x2 block. While
	// marks can exist, fetch the four texels, decode marked ones, and average them ourselves;
	// otherwise take the vanilla hardware sample.
	float3 SbmSample2x2(float2 uv, float2 texelSize)
	{
		BRANCH
		if (!SbmMarkingOn())
			return tex2DLod(Input, uv, 0, LinearClampCS).xyz;
		int2 size = tex2DSize(Input, 0).xy;
		float2 p = uv / texelSize - 0.5f;
		int2 p0 = clamp(int2(floor(p)), int2(0, 0), size - 1);
		int2 p1 = clamp(p0 + 1, int2(0, 0), size - 1);
		float2 f = saturate(p - floor(p));
		float3 a = SbmDecodeMark(tex2DFetch(Input, int2(p0.x, p0.y)).xyz);
		float3 b = SbmDecodeMark(tex2DFetch(Input, int2(p1.x, p0.y)).xyz);
		float3 cc = SbmDecodeMark(tex2DFetch(Input, int2(p0.x, p1.y)).xyz);
		float3 dd = SbmDecodeMark(tex2DFetch(Input, int2(p1.x, p1.y)).xyz);
		return lerp(lerp(a, b, f.x), lerp(cc, dd, f.x), f.y);
	}


	BEGIN_COMPUTE_SHADER(ThreadGroupSize, ThreadGroupSize, 1)
		float2 texelSize = InputTexelSize;
		float2 texturePos = (DISPATCH_THREAD_ID.xy * 2.0f + 1.0f) * texelSize ;

		// Store in shared memory
		samples[GROUP_THREAD_ID.y][GROUP_THREAD_ID.x + KernelRadius * 2] = SbmSample2x2(float2(texturePos.x + texelSize.x * KernelRadius * 2, texturePos.y), texelSize);
		if (GROUP_THREAD_ID.x < KernelRadius * 2)
			samples[GROUP_THREAD_ID.y][GROUP_THREAD_ID.x] = SbmSample2x2(float2(texturePos.x - texelSize.x * KernelRadius * 2, texturePos.y), texelSize);

		GroupMemoryBarrierWithGroupSync();

		if (all(lessThan(texturePos, broadcast2(1.0f))))
			RW_textureStore(Output, int2(DISPATCH_THREAD_ID.xy), BlurPixel(GROUP_THREAD_ID.yx));
	END_COMPUTE_SHADER

#elif defined(VGAUSS)

	DefineTexture2D(CS, Input, 0, FLOAT3_FMT);
	DefineRWTexture2D(Output, 0, FLOAT3_FMT, float_r11g11b10, NON_COHERENT);

	BEGIN_COMPUTE_SHADER(ThreadGroupSize, ThreadGroupSize, 1)
		int2 inputSize = tex2DSize(Output).xy - 1;
		int2 samplePos = int2(min(int(DISPATCH_THREAD_ID.x), inputSize.x), DISPATCH_THREAD_ID.y);

		// Store in shared memory
		samples[GROUP_THREAD_ID.x][GROUP_THREAD_ID.y + KernelRadius * 2] = SbmDecodeMark(tex2DFetch(Input, int2(samplePos.x, min(samplePos.y + KernelRadius, inputSize.y))).xyz);
		if (GROUP_THREAD_ID.y < KernelRadius * 2)
			samples[GROUP_THREAD_ID.x][GROUP_THREAD_ID.y] = SbmDecodeMark(tex2DFetch(Input, int2(samplePos.x, clamp(samplePos.y - KernelRadius, 0, inputSize.y))).xyz);
	
		GroupMemoryBarrierWithGroupSync();

		if (all(lessThanEqual(DISPATCH_THREAD_ID.xy, uint2(inputSize))))
			RW_textureStore(Output, int2(DISPATCH_THREAD_ID.xy), BlurPixel(GROUP_THREAD_ID.xy));
	END_COMPUTE_SHADER

#endif

#ifdef RENDER_STATE
	SLOTS_LAYOUT = MiscCompute;
#endif