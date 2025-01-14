#pragma once

#include <string>
#include <vector>
#include <cuda_runtime.h>
#include "glm/glm.hpp"

#include "common.h"
#include "cudaTexture.h"
#include "utilities.h"

#define BACKGROUND_COLOR (glm::vec3(0.0f))
static constexpr float ETA_AIR = 1.f;

enum GeomType {
    SPHERE,
    CUBE,
};

struct Ray 
{
    glm::vec3 origin;
    glm::vec3 direction;
    CPU_GPU Ray(const glm::vec3& o = {0, 0, 0}, const glm::vec3& d = { 0, 0, 0 })
        :origin(o), direction(d)
    {}

    CPU_GPU glm::vec3 operator*(const float& t) const { return origin + t * direction; }

public:
    CPU_GPU static Ray SpawnRay(const glm::vec3& o, const glm::vec3& dir)
    {
        return { o + dir * 0.001f, dir };
    }
};

struct Geom {
    enum GeomType type;
    int materialid;
    glm::vec3 translation;
    glm::vec3 rotation;
    glm::vec3 scale;
    glm::mat4 transform;
    glm::mat4 inverseTransform;
    glm::mat4 invTranspose;
};

enum MaterialType : unsigned int
{
    None                    = 0,
    Albedo_Texture          = BIT(27),
    Normal_Texture          = BIT(28),
    Roughness_Texture       = BIT(29),
    Metallic_Texture        = BIT(30),
    Clear_Texture           = ~(Albedo_Texture | Normal_Texture | Roughness_Texture | Metallic_Texture),
    Specular                = BIT(6),
    Microfacet              = BIT(7),
    DiffuseReflection       = 1,
    SpecularReflection      = Specular | 2,
    SpecularGlass           = Specular | 3,
    MicrofacetReflection    = Microfacet | 2,
    MicrofacetMix           = Microfacet | 3,
    SubsurfaceScattering    = 5,
};

#define TryStr2Type(str, type) if(str == #type) { return MaterialType::type;}

#define IsSpecular(type) ((MaterialType::Specular & type) > 0)
#define HasTexture(type, t_type) ((MaterialType::##t_type##_Texture & type) > 0)

inline MaterialType StringToMaterialType(const std::string& str)
{
    TryStr2Type(str, DiffuseReflection);
    TryStr2Type(str, SpecularReflection);
    TryStr2Type(str, SpecularGlass);
    TryStr2Type(str, MicrofacetReflection);
    TryStr2Type(str, MicrofacetMix);
    TryStr2Type(str, SubsurfaceScattering);
    
    return MaterialType::None;
}

struct Material 
{
    struct MaterialTextures
    {
        CudaTexture2D roughness_tex;
        CudaTexture2D metallic_tex;
        CudaTexture2D albedo_tex;
        CudaTexture2D normal_tex;
    };

    struct MaterialValues
    {
        float roughness = 0.f;
        float metallic = 0.f;
        glm::vec3 albedo = glm::vec3(0.f);
    };

    union MaterialUnionData
    {
        MaterialValues values;
        MaterialTextures textures;
        CPU_GPU MaterialUnionData() 
            : values()
        {
        }
        CPU_GPU MaterialUnionData(const MaterialUnionData& other)
            : values(other.values)
        {}
        inline CPU_GPU MaterialUnionData& operator=(const MaterialUnionData& other)
        {
            values = other.values;
            textures = other.textures;
        }
    };

    MaterialType type = MaterialType::None;
    float emittance = 0.f;
    float eta = ETA_AIR;
    MaterialUnionData data;
    CPU_GPU Material() {}

    CPU_GPU Material(const Material& other)
        :type(other.type), emittance(other.emittance), eta(other.eta), data(other.data)
    {}

    inline CPU_GPU Material& operator=(const Material& other)
    {
        type = other.type;
        emittance = other.emittance;
        eta = other.eta;
        data = other.data;

        return *this;
    }

    inline GPU_ONLY glm::vec3 GetAlbedo(const glm::vec2& uv) const 
    {
        if (HasTexture(type, Albedo) && data.textures.albedo_tex.Valid())
        {
            float4 tex_value = data.textures.albedo_tex.Get(uv.x, uv.y);
            return glm::vec3(tex_value.x, tex_value.y, tex_value.z);
        }
        else
        {
            return data.values.albedo;
        }
    }

    inline GPU_ONLY void GetNormal(const glm::vec2& uv, glm::vec3& normal) const
    {
        if (HasTexture(type, Normal) && data.textures.normal_tex.Valid())
        {
            float4 tex_value = data.textures.normal_tex.Get(uv.x, uv.y);
            glm::vec3 tex_normal(tex_value.x, tex_value.y, tex_value.z);
            normal = glm::normalize(LocalToWorld(normal) * tex_normal);
        }
    }

    inline GPU_ONLY float GetRoughness(const glm::vec2& uv) const
    {
        if (HasTexture(type, Roughness) && data.textures.roughness_tex.Valid())
        {
            float4 tex_value = data.textures.roughness_tex.Get(uv.x, uv.y);
            return tex_value.x;
        }
        else
        {
            return data.values.roughness;
        }
    }

    inline GPU_ONLY float GetMetallic(const glm::vec2& uv) const
    {
        if (HasTexture(type, Metallic) && data.textures.metallic_tex.Valid())
        {
            float4 tex_value = data.textures.metallic_tex.Get(uv.x, uv.y);
            return tex_value.x;
        }
        else
        {
            return data.values.metallic;
        }
    }
};

struct Camera {
    glm::ivec2 resolution;
    glm::vec3 position;
    glm::vec3 ref;
    glm::vec3 forward;
    glm::vec3 up;
    glm::vec3 right;
    float fovy;
    float lenRadius = 0.f;
    float focalDistance = 1.f;
    int path_depth;

    CPU_ONLY void Recompute() 
    {
        forward = glm::normalize(ref - position);
        right = glm::normalize(glm::cross(forward, {0, 1, 0}));
        up = glm::normalize(glm::cross(right, forward));
    }
};

struct RenderState {
    Camera camera;
    unsigned int iterations;
    int traceDepth;
    std::vector<glm::vec3> image;
    std::vector<uchar4> c_image;
    std::string imageName;
};

struct PathSegment {
    Ray ray;
    glm::vec3 throughput{ 1, 1, 1 };
    glm::vec3 radiance{0, 0, 0};

    int pixelIndex;
    int remainingBounces;
    int mediaId;
    CPU_GPU void Reset() 
    {
        throughput = glm::vec3(1.f);
        radiance = glm::vec3(0.f);
        pixelIndex = 0;
        mediaId = -1;
    }
    CPU_GPU void Terminate() { remainingBounces = 0; }
    CPU_GPU bool IsEnd() const { return remainingBounces <= 0; }
};

struct Intersection
{
    int shapeId;
    int materialId;
    float t;
    glm::vec2 uv; // local uv
};

// Use with a corresponding PathSegment to do:
// 1) color contribution computation
// 2) BSDF evaluation: generate a new ray
struct ShadeableIntersection 
{
    float t;
    glm::vec3 position;
    glm::vec3 normal;
    glm::vec2 uv;
    int materialId;

    CPU_GPU void Reset()
    {
        t = -1.f;
        materialId = -1;
    }
};

struct AABB
{
    CPU_ONLY AABB(const glm::vec3& _min = glm::vec3(Float_MAX),
                  const glm::vec3& _max = glm::vec3(Float_MIN))
        : m_Min(_min), m_Max(_max)
    {}
    glm::vec3 m_Min;
    glm::vec3 m_Max;
    
    glm::ivec3 m_Data; // leaf data or node data

    inline CPU_ONLY void Merge(const AABB& other)
    {
        m_Min = glm::min(m_Min, other.m_Min);
        m_Max = glm::max(m_Max, other.m_Max);
    }
    inline CPU_ONLY void Merge(const glm::vec3& p)
    {
        m_Min = glm::min(p, m_Min);
        m_Max = glm::max(p, m_Max);
    }
    inline CPU_ONLY glm::vec3 GetDiagnol() const { return m_Max - m_Min; }
    inline CPU_ONLY glm::vec3 GetCenter() const { return glm::vec3(0.5f) * (m_Min + m_Max);  }
    inline CPU_ONLY int GetMaxAxis() const
    {
        glm::vec3 d = GetDiagnol();
        return ((d.x > d.y && d.x > d.z) ? 0 : ((d.y > d.z) ? 1 : 2));
    }
    inline CPU_ONLY float GetCost() const
    {
        glm::vec3 d = GetDiagnol();
        return 2.0f * (d.x * d.y + d.x * d.z + d.y * d.z);
    }
    inline CPU_GPU bool Intersection(const Ray& ray, const glm::vec3& inv_dir, float& t) const 
    {
        glm::vec3 t_near = (m_Min - ray.origin) * inv_dir;
        glm::vec3 t_far = (m_Max - ray.origin) * inv_dir;

        glm::vec3 t_min = glm::min(t_near, t_far);
        glm::vec3 t_max = glm::max(t_near, t_far);

        t = glm::max(glm::max(t_min.x, t_min.y), t_min.z);

        if (t > glm::min(glm::min(t_max.x, t_max.y), t_max.z)) return false;

        return true;
    }
};

struct TriangleIdx
{
    TriangleIdx(const glm::ivec3 v, 
                const glm::ivec3& n, 
                const glm::ivec3& uv, 
                const unsigned int& material)
        :v_id(v), n_id(n), uv_id(uv), material(material)
    {}
    glm::ivec3 v_id;
    unsigned int material;
    glm::ivec3 n_id;
    glm::ivec3 uv_id;
};

struct BSDFSample
{
    glm::vec3 f = glm::vec3(0.f);
    glm::vec3 wiW = glm::vec3(0.f);
    float pdf = -1.f;
};

struct UniformMaterialData
{
    MaterialType type = MaterialType::DiffuseReflection;
    glm::vec3 albedo = glm::vec3(1.f);
    glm::vec3 ss_absorption_coeffi = glm::vec3(1.f);
    float ss_scatter_coeffi = 1.f;
    float roughness = 0.f;
    float metallic = 1.f;
    float eta = 1.5f;
};
