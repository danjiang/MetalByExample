#include <metal_stdlib>
#include <metal_matrix>

using namespace metal;

struct Light
{
  float3 direction;
  float3 ambientColor;
  float3 diffuseColor;
  float3 specularColor;
};

constant Light light = {
  .direction = { 0.13, 0.72, 0.68 },
  .ambientColor = { 0.05, 0.05, 0.05 },
  .diffuseColor = { 1, 1, 1 },
  .specularColor = { 0.2, 0.2, 0.2 }
};

constant float3 kSpecularColor= { 1, 1, 1 };
constant float kSpecularPower = 80;

struct Vertex
{
  packed_float4 position;
  packed_float4 normal;
  packed_float2 texCoords;
};

struct ProjectedVertex
{
  float4 position [[position]];
  float3 eye;
  float3 normal;
  float2 texCoords;
};

struct Uniforms
{
  float4x4 modelViewProjectionMatrix;
  float4x4 modelViewMatrix;
  float3x3 normalMatrix;
};

vertex ProjectedVertex vertex_project(device Vertex *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]],
                             uint vid [[vertex_id]])
{
  float4 position = vertices[vid].position;
  float4 normal = vertices[vid].normal;

  ProjectedVertex vertexOut;
  vertexOut.position = uniforms.modelViewProjectionMatrix * position;
  vertexOut.eye = -(uniforms.modelViewMatrix * position).xyz;
  vertexOut.normal = uniforms.normalMatrix * normal.xyz;
  vertexOut.texCoords = vertices[vid].texCoords;
  return vertexOut;
}

fragment float4 fragment_texture(ProjectedVertex vertexIn [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]],
                                 texture2d<float> diffuseTexture [[texture(0)]],
                                 sampler samplr [[sampler(0)]])
{
  float3 diffuseColor = diffuseTexture.sample(samplr, vertexIn.texCoords).rgb;

  float3 ambientTerm = light.ambientColor * diffuseColor;
  
  float3 normal = normalize(vertexIn.normal);
  float diffuseIntensity = saturate(dot(normal, light.direction));
  float3 diffuseTerm = light.diffuseColor * diffuseColor * diffuseIntensity;
  
  float3 specularTerm(0);
  if (diffuseIntensity > 0)
  {
    float3 eyeDirection = normalize(vertexIn.eye);
    float3 halfway = normalize(light.direction + eyeDirection);
    float specularFactor = pow(saturate(dot(normal, halfway)), kSpecularPower);
    specularTerm = light.specularColor * kSpecularColor * specularFactor;
  }
  
  return float4(ambientTerm + diffuseTerm + specularTerm, 1);
}
