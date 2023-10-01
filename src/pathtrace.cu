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

struct CompactTerminatedPaths {
	CPU_GPU bool operator() (const PathSegment& segment) {
		return !(segment.pixelIndex >= 0 && segment.IsEnd());
	}
};

struct RemoveInvalidPaths {
	CPU_GPU bool operator() (const PathSegment& segment) {
		return segment.pixelIndex < 0 || segment.IsEnd();
	}
};

CPU_ONLY CudaPathTracer::~CudaPathTracer()
{
	// free ptr
	SafeCudaFree(dev_hdr_img);  // no-op if dev_image is null
	SafeCudaFree(dev_paths);
	SafeCudaFree(dev_geoms);
	SafeCudaFree(dev_materials);
	SafeCudaFree(dev_intersections);

	if (cuda_pbo_dest_resource)
	{
		UnRegisterPBO();
	}

	checkCUDAError("CudaPathTracer delete Error!");
}

CPU_ONLY GPU_ONLY thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
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
	
	// write color
	pixel = { static_cast<unsigned char>(hdr_pixel.r), 
			  static_cast<unsigned char>(hdr_pixel.g), 
			  static_cast<unsigned char>(hdr_pixel.b), 
			  255 };
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution, glm::vec3* image) 
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x >= resolution.x || y >= resolution.y) return;

	int index = x + (y * resolution.x);
	glm::vec3 pix = image[index];

	//int write_index = (resolution.x - x - 1) + (y * resolution.x);
	writePixel(pix, pbo[index]);
}

static GuiDataContainer* guiData = nullptr;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
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
		
		CudaRNG rng(iter, index, 0);

		segment.ray = cam.CastRay({x + rng.rand(), y + rng.rand()});
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;

		pathSegments[index] = segment;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(int num_paths, PathSegment* pathSegments, ShadeableIntersection* intersections, GPUScene scene)
{
	int index = blockIdx.x * blockDim.x + threadIdx.x;

	if (index >= num_paths) return;
	
	PathSegment segment = pathSegments[index];
	ShadeableIntersection& shadeable_intersection = intersections[index];
	shadeable_intersection.Reset();

	if (segment.IsEnd()) return;

	Intersection intersection = scene.SceneIntersection(segment.ray);
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

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	//int idx = blockIdx.x * blockDim.x + threadIdx.x;
	//if (idx < num_paths)
	//{
	//	ShadeableIntersection intersection = shadeableIntersections[idx];
	//	if (intersection.t > 0.0f) { // if the intersection exists...
	//	  // Set up the RNG
	//	  // LOOK: this is how you use thrust's RNG! Please look at
	//	  // makeSeededRandomEngine as well.
	//		thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
	//		thrust::uniform_real_distribution<float> u01(0, 1);

	//		Material material = materials[intersection.materialId];
	//		glm::vec3 materialColor = material.albedo;

	//		// If the material indicates that the object was a light, "light" the ray
	//		if (material.emittance > 0.0f) {
	//			pathSegments[idx].throughput *= (materialColor * material.emittance);
	//		}
	//		// Otherwise, do some pseudo-lighting computation. This is actually more
	//		// like what you would expect from shading in a rasterizer like OpenGL.
	//		// TODO: replace this! you should be able to start with basically a one-liner
	//		else {
	//			float lightTerm = glm::dot(intersection.normal, glm::vec3(0.0f, 1.0f, 0.0f));
	//			pathSegments[idx].throughput *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
	//			pathSegments[idx].throughput *= u01(rng); // apply some noise because why not
	//		}
	//		// If there was no intersection, color the ray black.
	//		// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
	//		// used for opacity, in which case they can indicate "no opacity".
	//		// This can be useful for post-processing and image compositing.
	//	}
	//	else {
	//		pathSegments[idx].throughput = glm::vec3(0.0f);
	//	}
	//}
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
__global__ void KernelNaiveGI(int iteration, int num_paths, 
							ShadeableIntersection* shadeableIntersections,
							PathSegment* pathSegments,
							Material* materials, EnvironmentMap env_map)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx >= num_paths) return;

	ShadeableIntersection intersection = shadeableIntersections[idx];
	PathSegment segment = pathSegments[idx];

	if (intersection.materialId >= 0)
	{
		//pathSegments[idx].radiance = intersection.normal * 0.5f + 0.5f;
		//return;	
		
		Material material = materials[intersection.materialId];
		glm::vec3 materialColor = material.GetAlbedo(intersection.uv);
		
		if (material.emittance > 0.f) 
		{
			glm::vec3 final_throughput = segment.throughput * material.emittance;
			pathSegments[idx].radiance = final_throughput;
			pathSegments[idx].Terminate();
		}
		else
		{	
			material.GetNormal(intersection.uv, intersection.normal);

			CudaRNG rng(iteration, idx, segment.remainingBounces);
			BSDFSample bsdf_sample;
			bsdf_sample.wiW = -segment.ray.direction;
			SampleBSDF::Sample(material, intersection, segment.eta, rng, bsdf_sample);

			// generate new ray
			pathSegments[idx].ray = Ray::SpawnRay(intersection.position, bsdf_sample.wiW);
			pathSegments[idx].throughput *= bsdf_sample.f * glm::abs(glm::dot(bsdf_sample.wiW, intersection.normal)) / bsdf_sample.pdf;
			pathSegments[idx].eta = material.eta;
			--pathSegments[idx].remainingBounces;
		}
	}
	else
	{
		if (env_map.Valid())
		{
			pathSegments[idx].radiance = segment.throughput * glm::clamp(env_map.Get(segment.ray.direction), 0.f, 1000.f);
		}
		
		pathSegments[idx].Terminate();
	}
}

CPU_ONLY void CudaPathTracer::Init(Scene* scene)
{
	m_Iteration = 0;

	const Camera& cam = scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;
	
	resolution = cam.resolution;

	cudaMalloc(&dev_hdr_img, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_hdr_img, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));
	cudaMalloc(&dev_terminated_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	// TODO: initialize any extra device memeory you need

	thrust_dev_paths = thrust::device_ptr<PathSegment>(dev_paths);
	thrust_dev_terminated_paths = thrust::device_ptr<PathSegment>(dev_terminated_paths);

	checkCUDAError("pathtraceInit");
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

CPU_ONLY void CudaPathTracer::Render(GPUScene& scene, const Camera& camera)
{
	const int pixelcount = camera.resolution.x * camera.resolution.y;

	// TODO: might change to dynamic block size
	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(camera.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(camera.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (camera, m_Iteration, 8, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (depth < 8 && num_paths > 0) 
	{
		depth++;

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		computeIntersections<<<numblocksPathSegmentTracing, blockSize1d>>>(num_paths, dev_paths, dev_intersections, scene);
		checkCUDAError("Intersection Error");
		cudaDeviceSynchronize();

		KernelNaiveGI<<<numblocksPathSegmentTracing, blockSize1d >>>(m_Iteration, num_paths,
																	 dev_intersections, dev_paths, dev_materials, scene.env_map);
		checkCUDAError("NaiveGI Error");
		cudaDeviceSynchronize();

		if (guiData != nullptr)
		{
			guiData->TracedDepth = depth;
		}
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;

	float u = 1.f / static_cast<float>(m_Iteration + 1); // used for interpolation between last frame and this frame

	finalGather << <numBlocksPixels, blockSize1d >> > (u, num_paths, dev_hdr_img, dev_paths);
	checkCUDAError("Final Gather failed");
	cudaDeviceSynchronize();
	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (dev_img, camera.resolution, dev_hdr_img);

	checkCUDAError("pathtrace");
	++m_Iteration;
}