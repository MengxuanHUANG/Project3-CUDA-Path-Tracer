#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <GL/glew.h>
#include <cuda_gl_interop.h>

#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#include "gpuScene.h"
#include "scene.h"
#include "rng.h"
#include "cudaTexture.h"

static constexpr int Compact_Threshold = 2073600;

struct CopyEndPaths 
{
	CPU_GPU bool operator() (const PathSegment& segment) {
		return segment.IsEnd();
	}
};

struct RemoveEndPaths 
{
	CPU_GPU bool operator() (const PathSegment& segment) {
		return segment.pixelIndex < 0 || segment.IsEnd();
	}
};

CPU_ONLY CudaPathTracer::~CudaPathTracer()
{
	// free ptr
	SafeCudaFree(dev_hdr_img);  // no-op if dev_image is null
	SafeCudaFree(dev_paths);
	SafeCudaFree(dev_end_paths);
	SafeCudaFree(dev_intersections);
	SafeCudaFree(dev_gbuffer);
	SafeCudaFree(dev_denoised_img_r);
	SafeCudaFree(dev_denoised_img_w);

	if (cuda_pbo_dest_resource)
	{
		UnRegisterPBO();
	}

	checkCUDAError("Free cuda pointers Error!");
}

GPU_ONLY float4 CudaTexture2D::Get(const float& x, const float& y) const
{
	return tex2D<float4>(m_TexObj, x, y);
}

CPU_GPU void writePixel(glm::vec3& hdr_pixel, uchar4& pixel)
{
	// tone mapping
	hdr_pixel = hdr_pixel / (1.f + hdr_pixel);

	// gammar correction
	hdr_pixel = glm::pow(hdr_pixel, glm::vec3(1.f / 2.2f));

	// map to [0, 255]
	hdr_pixel = glm::mix(glm::vec3(0.f), glm::vec3(255.f), hdr_pixel);
	
	hdr_pixel = glm::clamp(hdr_pixel, 0.f, 255.f);

	// write color
	pixel = { static_cast<unsigned char>(hdr_pixel.r), 
			  static_cast<unsigned char>(hdr_pixel.g), 
			  static_cast<unsigned char>(hdr_pixel.b), 
			  255 };
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution, glm::vec3* image, GInfo* gbuffer, DisplayMode mode) 
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x >= resolution.x || y >= resolution.y) return;
	int index = (x + (y * resolution.x));
	glm::vec3 pix;
	switch (mode)
	{
	case DisplayMode::Color:
	{
		pix = gbuffer[index].albedo * image[index];
		break;
	}
	case DisplayMode::Normal:
	{
		pix = gbuffer[index].normal * 0.5f + 0.5f;
		break;
	}
	case DisplayMode::Position:
	{
		pix = (gbuffer[index].position / 2.f) * 0.5f + 0.5f;
		break;
	}
	default:
		pix = glm::vec3(0.f);
	}

	writePixel(pix, pbo[index]);
}

static GuiDataContainer* guiData = nullptr;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

CPU_GPU Ray CastRay(const Camera& camera, const glm::vec2& p, const glm::vec2& rand_offset)
{
	glm::vec2 ndc = 2.f * p / glm::vec2(camera.resolution);
	ndc.x = ndc.x - 1.f;
	ndc.y = 1.f - ndc.y;

	float aspect = static_cast<float>(camera.resolution.x) / static_cast<float>(camera.resolution.y);

	// point in camera space
	float radian = glm::radians(camera.fovy * 0.5f);
	glm::vec3 p_camera = glm::vec3(
		ndc.x * glm::tan(radian) * aspect,
		ndc.y * glm::tan(radian),
		1.f
	);

	Ray ray(glm::vec3(0), p_camera);

	// len camera
	glm::vec2 p_len = camera.lenRadius * SquareToDiskConcentric(rand_offset);
	glm::vec3 p_focal = camera.focalDistance * p_camera;
	ray.origin.x = p_len.x;
	ray.origin.y = p_len.y;
	ray.direction = glm::normalize(p_focal - ray.origin);

	// transform to world space
	ray.origin = camera.position + ray.origin.x * camera.right + ray.origin.y * camera.up;
	ray.direction = glm::normalize(
		ray.direction.z * camera.forward +
		ray.direction.y * camera.up +
		ray.direction.x * camera.right
	);

	return ray;
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) 
	{
		int index = x + (y * cam.resolution.x);
		PathSegment segment;
		segment.Reset();

		CudaRNG rng(iter, index, 0);

		glm::vec2 coord = { x, y };
		
		coord += glm::vec2(rng.rand(), rng.rand());

		segment.ray = CastRay(cam, coord, { rng.rand(), rng.rand() });
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;

		pathSegments[index] = segment;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(int num_paths, 
									PathSegment* pathSegments, 
									ShadeableIntersection* intersections, 
									GPUScene scene)
{
	int index = blockIdx.x * blockDim.x + threadIdx.x;

	if (index >= num_paths) return;
	
	PathSegment segment = pathSegments[index];
	ShadeableIntersection& shadeable_intersection = intersections[index];
	shadeable_intersection.Reset();

	if (segment.remainingBounces <= 0) return;

	Intersection intersection = scene.SceneIntersection(segment.ray, threadIdx.x);
	if (intersection.shapeId >= 0)
	{
		ShadeableIntersection shadeable;
		shadeable.t = intersection.t;
		shadeable.position = segment.ray * intersection.t;
		glm::ivec3 n_id = scene.dev_triangles[intersection.shapeId].n_id;
		glm::ivec3 uv_id = scene.dev_triangles[intersection.shapeId].uv_id;

		shadeable.normal = BarycentricInterpolation<glm::vec3>(scene.dev_normals[n_id.x],
															   scene.dev_normals[n_id.y],
															   scene.dev_normals[n_id.z], intersection.uv);;
		shadeable.normal = glm::normalize(shadeable.normal);
		shadeable.uv = BarycentricInterpolation<glm::vec2>(scene.dev_uvs[uv_id.x], 
														   scene.dev_uvs[uv_id.y], 
														   scene.dev_uvs[uv_id.z], intersection.uv);;
		shadeable.materialId = intersection.materialId;

		shadeable_intersection = shadeable;
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(float u, int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index >= nPaths) return;

	PathSegment segment = iterationPaths[index];

	glm::vec3 pre_color = image[segment.pixelIndex];
	glm::vec3 new_color = glm::mix(pre_color, segment.radiance, u);

	image[segment.pixelIndex] = new_color;
}

// Naive BSDF sample only
__global__ void KernelNaiveGI(const int iteration, const int num_paths, const int num_materials,
							ShadeableIntersection* shadeableIntersections,
							PathSegment* pathSegments,
							GInfo* gbuffer,
							const Material* materials, EnvironmentMap env_map, 
							const UniformMaterialData u_data, bool cache_gbuffer)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= num_paths) return;
	
	__shared__ Material shared_materials[128];
	if (blockDim.x >= num_materials)
	{
		if (threadIdx.x < 128 && threadIdx.x < num_materials)
		{
			shared_materials[threadIdx.x] = materials[threadIdx.x];
		}
		__syncthreads();
	}

	PathSegment segment = pathSegments[idx];
	if (segment.IsEnd()) return;
	ShadeableIntersection intersection = shadeableIntersections[idx];
	
	if (intersection.materialId >= 0)
	{
		if (segment.mediaId >= 0)
		{
			CudaRNG rng(iteration, idx, segment.remainingBounces);

			const float distance = -glm::log(rng.rand()) / u_data.ss_scatter_coeffi;
			if (distance < 1000.f)
			{
				if (distance < intersection.t)
				{
					Ray ray(segment.ray.origin + segment.ray.direction * distance, SquareToSphereUniform({ rng.rand(), rng.rand() }));
					pathSegments[idx].ray = ray;

					const float weight = glm::exp(-u_data.ss_scatter_coeffi * distance);
					const float pdf = Inv4Pi;
					const glm::vec3 transmission = glm::exp(-u_data.ss_absorption_coeffi * distance);
					pathSegments[idx].throughput *= transmission * glm::max(weight, 0.1f);
					return;
				}
				else
				{
					pathSegments[idx].throughput *= glm::exp(-u_data.ss_absorption_coeffi * intersection.t);
					const glm::vec3 transmission = glm::exp(-u_data.ss_absorption_coeffi * intersection.t);
					pathSegments[idx].throughput *= transmission;
				}
			}
		}
		
		Material material;
		if (blockDim.x >= num_materials)
		{
			material = materials[intersection.materialId];
		}
		else
		{
			Material material = shared_materials[intersection.materialId];
		}

		if (intersection.materialId == 0)
		{
			material.type = u_data.type;
			material.eta = u_data.eta;
			material.data.values.albedo = u_data.albedo;
			material.data.values.metallic = u_data.metallic;
			material.data.values.roughness = u_data.roughness;
		}

		if (material.emittance > 0.f) 
		{
			glm::vec3 final_throughput = segment.throughput * material.emittance;
			pathSegments[idx].radiance = final_throughput;
			pathSegments[idx].Terminate();
			if (cache_gbuffer)
			{
				GInfo info;
				info.normal = intersection.normal;
				info.position = intersection.position;
				info.albedo = glm::vec3(1.f);
				gbuffer[idx] = info;
			}
		}
		else
		{	
			material.GetNormal(intersection.uv, intersection.normal);
			
			if (cache_gbuffer)
			{
				GInfo info;
				info.normal = intersection.normal;
				info.position = intersection.position;
				info.albedo = glm::vec3(1.f);
				gbuffer[idx] = info;
			}

			CudaRNG rng(iteration, idx, segment.remainingBounces);
			BSDFSample bsdf_sample;
			bsdf_sample.wiW = -segment.ray.direction;
			if(SampleBSDF::Sample(material, intersection, rng, bsdf_sample))
			{
				// generate new ray
				pathSegments[idx].ray = Ray::SpawnRay(intersection.position, bsdf_sample.wiW);
				glm::vec3 throughput = glm::clamp(bsdf_sample.f * glm::abs(glm::dot(bsdf_sample.wiW, intersection.normal)) / bsdf_sample.pdf, glm::vec3(0.1f), glm::vec3(1.f));
#if EXTRACT_FIRST_ALBEDO
				if (cache_gbuffer)
				{
					gbuffer[idx].albedo = throughput;
				}
				else
				{
					pathSegments[idx].throughput *= throughput;
				}
#else
				pathSegments[idx].throughput *= throughput;
#endif
				--pathSegments[idx].remainingBounces;

				if (MaterialType::SubsurfaceScattering == material.type)
				{
					pathSegments[idx].mediaId = segment.mediaId >= 0 ? -1: 0;
				}
			}
			else
			{
				pathSegments[idx].remainingBounces = 0;
				return;
			}
		}
	}
	else
	{
		if (cache_gbuffer)
		{
			gbuffer[idx].normal = glm::vec3(0.f);
			gbuffer[idx].albedo = glm::vec3(1.f);
		}
		if (env_map.Valid())
		{
			pathSegments[idx].radiance = segment.throughput * glm::clamp(env_map.Get(segment.ray.direction), 0.f, 200.f);
		}
		pathSegments[idx].Terminate();
	}
}

__global__ void KernelDisplayNormal(const int iteration, const int num_paths, const int num_materials,
										ShadeableIntersection* shadeableIntersections,
										PathSegment* pathSegments,
										const Material* materials)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= num_paths) return;

	PathSegment segment = pathSegments[idx];
	if (segment.IsEnd()) return;
	ShadeableIntersection intersection = shadeableIntersections[idx];

	if (intersection.materialId >= 0)
	{
		Material material = materials[intersection.materialId];
		material.GetNormal(intersection.uv, intersection.normal);
		pathSegments[idx].radiance = intersection.normal * 0.5f + 0.5f;
	}
	pathSegments[idx].Terminate();
	return;
}

__global__ void KernelDenoise(const glm::ivec2 resolution, const GInfo* gbuffer, 
								const glm::vec3* denoised_img_r, glm::vec3* denoised_img_w, 
								const float color_phi, const float normal_phi, const float position_phi, 
								const int step_size)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x >= resolution.x || y >= resolution.y) return;
	int index = (x + (y * resolution.x));

	glm::vec3 color = denoised_img_r[index];
	glm::vec3 normal = gbuffer[index].normal;
	glm::vec3 position = gbuffer[index].position;
	if (glm::dot(normal, normal) < 0.1f)
	{
		denoised_img_w[index] = denoised_img_r[index];
		return;
	}

	float cum_weight = 0.f;
	glm::vec3 sum = glm::vec3(0.f);
	
	const float kernel[5]{1.f / 16.f, 1.f / 4.f, 3.f / 8.f, 1.f/ 4.f, 1.f / 16.f};
 	for (int h = -2; h <= 2; ++h)
	{
		for (int w = -2; w <= 2; ++w)
		{
			const int id = index + (w + h * (resolution.x)) * step_size;
			if (id >= 0 && id < resolution.x * resolution.y)
			{
				const glm::vec3 color_temp = denoised_img_r[id];
				glm::vec3 t = color - color_temp;
				float dist2 = glm::dot(t, t);
				
				float color_weight = glm::min(glm::exp(-dist2 / color_phi), 1.f);
				
				GInfo info = gbuffer[id];
				t = normal - info.normal;
				dist2 = glm::min(glm::dot(t, t) / (step_size * step_size), 0.f);
				float normal_weight = glm::min(glm::exp(-dist2 / normal_phi), 1.f);
				
				t = position - info.position;
				dist2 = glm::dot(t, t);
				float position_weight = glm::min(glm::exp(-dist2 / position_phi), 1.f);
				
				float weight = color_weight * normal_weight * position_weight;
				sum += color_temp * weight * kernel[(w + 2)] * kernel[(h + 2)];
				cum_weight += weight * kernel[(w + 2)] * kernel[(h + 2)];
			}
		}
	}
	cum_weight = cum_weight > Epsilon ? cum_weight : 1.f;
	denoised_img_w[index] = sum / cum_weight;
}

__global__ void KernelGaussianDenoise(const glm::ivec2 resolution, const glm::vec3* denoised_img_r, glm::vec3* denoised_img_w, float sigma, int size)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x >= resolution.x || y >= resolution.y) return;
	int index = (x + (y * resolution.x));

	glm::vec3 sum = glm::vec3(0.f);

	float cum_weight = 0.f;
	for (int h = -size; h <= size; ++h)
	{
		for (int w = -size; w <= size; ++w)
		{
			const int id = index + (w + h * (resolution.x));
			if (id >= 0 && id < resolution.x * resolution.y)
			{
				float scalar = (1.0 / (2.0 * Pi * sigma * sigma)) * exp(-(h * h + w * w) / (2.0 * sigma * sigma));
				cum_weight += scalar;
				sum += denoised_img_r[id] * scalar;
			}
		}
	}
	denoised_img_w[index] = sum / cum_weight;
}

CPU_ONLY void CudaPathTracer::Resize(const int& w, const int& h)
{
	resolution.x = w;
	resolution.y = h;

	SafeCudaFree(dev_hdr_img);  // no-op if dev_image is null
	SafeCudaFree(dev_denoised_img_r);
	SafeCudaFree(dev_denoised_img_w);
	SafeCudaFree(dev_gbuffer);
	SafeCudaFree(dev_paths);
	SafeCudaFree(dev_end_paths);
	SafeCudaFree(dev_intersections);

	if (cuda_pbo_dest_resource)
	{
		UnRegisterPBO();
	}
	const int pixelcount = resolution.x * resolution.y;
	
	checkCUDAError("Get PBO pointer Error");

	cudaMalloc(&dev_hdr_img, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_hdr_img, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_denoised_img_r, pixelcount * sizeof(glm::vec3));
	cudaMalloc(&dev_denoised_img_w, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));
	cudaMalloc(&dev_end_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_gbuffer, pixelcount * sizeof(GInfo));

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	thrust_dev_paths_begin = thrust::device_ptr<PathSegment>(dev_paths);
	thrust_dev_end_paths_bgein = thrust::device_ptr<PathSegment>(dev_end_paths);
}

void CudaPathTracer::Init(Scene* scene)
{
	m_Iteration = 1;

	const Camera& cam = scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;
	
	resolution = cam.resolution;

	cudaMalloc(&dev_hdr_img, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_hdr_img, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_denoised_img_r, pixelcount * sizeof(glm::vec3));
	cudaMalloc(&dev_denoised_img_w, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));
	cudaMalloc(&dev_end_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_gbuffer, pixelcount * sizeof(GInfo));

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	thrust_dev_paths_begin = thrust::device_ptr<PathSegment>(dev_paths);
	thrust_dev_end_paths_bgein = thrust::device_ptr<PathSegment>(dev_end_paths);

	checkCUDAError("Create device image error");
}

CPU_ONLY void CudaPathTracer::GetImage(uchar4* host_image)
{
	//Retrieve image from GPU
	cudaMemcpy(host_image, dev_img, resolution.x * resolution.y * sizeof(uchar4), cudaMemcpyDeviceToHost);
}

CPU_ONLY void CudaPathTracer::RegisterPBO(unsigned int pbo)
{
	cudaGraphicsGLRegisterBuffer(&cuda_pbo_dest_resource, pbo, cudaGraphicsMapFlagsNone);
	size_t byte_count = resolution.x * resolution.y * 4 * sizeof(uchar4);
	cudaGraphicsMapResources(1, &cuda_pbo_dest_resource, 0);
	cudaGraphicsResourceGetMappedPointer((void**)&dev_img, &byte_count, cuda_pbo_dest_resource);
	checkCUDAError("Get PBO pointer Error");
}

CPU_ONLY void CudaPathTracer::Render(GPUScene& scene, 
									 const Camera& camera,
									 const UniformMaterialData& data)
{
	if (m_Iteration > m_MaxIteration) return;
	const int pixelcount = resolution.x * resolution.y;

	const int& max_depth = camera.path_depth;
	// TODO: might change to dynamic block size
	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (camera, m_Iteration, max_depth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;

	int num_paths = pixelcount;

	thrust::device_ptr<PathSegment> thrust_end_paths_end = thrust_dev_end_paths_bgein;
	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (depth < max_depth && num_paths > 0)
	{
		depth++;

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		computeIntersections<<<numblocksPathSegmentTracing, blockSize1d>>>(num_paths, dev_paths, dev_intersections, scene);
		checkCUDAError("Intersection Error");
		cudaDeviceSynchronize();
#if DebugNormal
		KernelDisplayNormal << <numblocksPathSegmentTracing, blockSize1d >> > (m_Iteration, num_paths, scene.material_count,
																				dev_intersections, dev_paths, scene.dev_materials);
#else
		KernelNaiveGI<<<numblocksPathSegmentTracing, blockSize1d >>>(m_Iteration, num_paths, scene.material_count,
																	 dev_intersections, dev_paths, 
																	 dev_gbuffer,
																	 scene.dev_materials, scene.env_map,								 
																	 data, depth == 1);
		checkCUDAError("NaiveGI Error");
#endif
		cudaDeviceSynchronize();
		if (pixelcount >= Compact_Threshold)
		{
			// remove terminated segments
			thrust_end_paths_end = thrust::copy_if(thrust_dev_paths_begin, thrust_dev_paths_begin + num_paths, thrust_end_paths_end, CopyEndPaths());
			auto remove_ptr = thrust::remove_if(thrust_dev_paths_begin, thrust_dev_paths_begin + num_paths, CopyEndPaths());

			num_paths = remove_ptr - thrust_dev_paths_begin;
		}
	}

	// Assemble this iteration and apply it to the image
	float u = 1.f / static_cast<float>(m_Iteration); // used for interpolation between last frame and this frame
	if (pixelcount >= Compact_Threshold)
	{
		int num_end_paths = thrust_end_paths_end - thrust_dev_end_paths_bgein;
		dim3 numBlocksPixels = (num_end_paths + blockSize1d - 1) / blockSize1d;

		finalGather << <numBlocksPixels, blockSize1d >> > (u, num_end_paths, dev_hdr_img, dev_end_paths);
	}
	else
	{
		dim3 numBlocksPixels = (num_paths + blockSize1d - 1) / blockSize1d;

		finalGather << <numBlocksPixels, blockSize1d >> > (u, num_paths, dev_hdr_img, dev_paths);
	}
	checkCUDAError("Final Gather failed");

	if (m_DenoiseConfig.denoise)
	{
		cudaMemcpy(dev_denoised_img_r, dev_hdr_img, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);
#if A_TROUS_DENOISE
		// denoise pass
		for(int it = 1, step = 1; it <= m_DenoiseConfig.level; ++it, step <<= 1)
		{
			float scaler = 1.f;// pow(2, -it);
			KernelDenoise << <blocksPerGrid2d, blockSize2d >> > (resolution, dev_gbuffer, 
																 dev_denoised_img_r, dev_denoised_img_w, 
																 m_DenoiseConfig.colorWeight * scaler,
																 m_DenoiseConfig.normalWeight * scaler,
																 m_DenoiseConfig.positionWeight * scaler,
																 step);

			std::swap(dev_denoised_img_r, dev_denoised_img_w);
		}
#elif GAUSSIAN_DENOISE
		KernelGaussianDenoise << <blocksPerGrid2d, blockSize2d >> > (resolution, dev_denoised_img_r, dev_denoised_img_w, m_DenoiseConfig.colorWeight, m_DenoiseConfig.level);
		std::swap(dev_denoised_img_r, dev_denoised_img_w);
#endif
		sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (dev_img, resolution, dev_denoised_img_r, dev_gbuffer, m_DisplayMode);
	}
	else
	{
		// Send results to OpenGL buffer for rendering
		sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (dev_img, resolution, dev_hdr_img, dev_gbuffer, m_DisplayMode);
	}
	//cudaDeviceSynchronize();
	///////////////////////////////////////////////////////////////////////////

	checkCUDAError("pathtrace");
	++m_Iteration;
}