//
//  MBERenderer.m
//  MetalByExample
//
//  Created by Dan Jiang on 2018/7/3.
//  Copyright © 2018年 Dan Jiang. All rights reserved.
//

#import "MBERenderer.h"
#import "MBEMathUtilities.h"
#import "MBEOBJModel.h"
#import "MBEOBJGroup.h"
#import "MBEOBJMesh.h"
#import "MBETypes.h"
#import "MBETextureLoader.h"
@import Metal;
@import simd;

static const NSInteger MBEInFlightBufferCount = 3;

@interface MBERenderer ()

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLTexture> diffuseTexture;
@property (nonatomic, strong) MBEMesh *mesh;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLDepthStencilState> depthStencilState;
@property (nonatomic, strong) id<MTLSamplerState> samplerState;
@property (nonatomic, strong) dispatch_semaphore_t displaySemaphore;
@property (nonatomic, assign) float rotationX, rotationY, time;
@property (nonatomic, assign) NSInteger bufferIndex;

@end

@implementation MBERenderer

- (instancetype)init {
  self = [super init];
  if (self) {
    [self makeDevice];
    _displaySemaphore = dispatch_semaphore_create(MBEInFlightBufferCount);
    [self makePipeline];
    [self makeResources];
  }
  return self;
}

- (void)updateUniformsForView:(MBEMetalView *)view duration:(NSTimeInterval)duration {
  self.time += duration;
  self.rotationX += duration * (M_PI / 2);
  self.rotationY += duration * (M_PI / 3);
  float scaleFactor = 1;
  const vector_float3 xAxis = { 1, 0, 0 };
  const vector_float3 yAxis = { 0, 1, 0 };
  const matrix_float4x4 xRot = matrix_float4x4_rotation(xAxis, self.rotationX);
  const matrix_float4x4 yRot = matrix_float4x4_rotation(yAxis, self.rotationY);
  const matrix_float4x4 scale = matrix_float4x4_uniform_scale(scaleFactor);
  const matrix_float4x4 modelMatrix = matrix_multiply(matrix_multiply(xRot, yRot), scale);
  
  const vector_float3 cameraTranslation = { 0, 0, -1.5 };
  const matrix_float4x4 viewMatrix = matrix_float4x4_translation(cameraTranslation);
  
  const CGSize drawableSize = view.metalLayer.drawableSize;
  const float aspect = drawableSize.width / drawableSize.height;
  const float fov = (2 * M_PI) / 5;
  const float near = 0.1;
  const float far = 100;
  const matrix_float4x4 projectionMatrix = matrix_float4x4_perspective(aspect, fov, near, far);
  
  MBEUniforms uniforms;
  uniforms.modelViewMatrix = matrix_multiply(viewMatrix, modelMatrix);
  uniforms.modelViewProjectionMatrix = matrix_multiply(projectionMatrix, uniforms.modelViewMatrix);
  uniforms.normalMatrix = matrix_float4x4_extract_linear(uniforms.modelViewMatrix);

  const NSUInteger uniformBufferOffset = sizeof(MBEUniforms) * self.bufferIndex;
  memcpy([self.uniformBuffer contents] + uniformBufferOffset, &uniforms, sizeof(uniforms));
}

- (void)drawInView:(MBEMetalView *)view {
  dispatch_semaphore_wait(self.displaySemaphore, DISPATCH_TIME_FOREVER);
  
  view.clearColor = MTLClearColorMake(0.95, 0.95, 0.95, 1);

  [self updateUniformsForView:view duration:view.frameDuration];
  
  id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
  
  MTLRenderPassDescriptor *passDescriptor = [view currentRenderPassDescriptor];

  id<MTLRenderCommandEncoder> renderPass = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
  [renderPass setRenderPipelineState:self.pipeline];
  [renderPass setDepthStencilState:self.depthStencilState];
  [renderPass setFrontFacingWinding:MTLWindingCounterClockwise];
  [renderPass setCullMode:MTLCullModeBack];
  
  const NSUInteger uniformBufferOffset = sizeof(MBEUniforms) * self.bufferIndex;
  [renderPass setVertexBuffer:self.uniformBuffer offset:uniformBufferOffset atIndex:1];

  [renderPass setVertexBuffer:self.mesh.vertexBuffer offset:0 atIndex:0];
  
  [renderPass setFragmentTexture:self.diffuseTexture atIndex:0];
  [renderPass setFragmentSamplerState:self.samplerState atIndex:0];
  
  [renderPass drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                         indexCount:[self.mesh.indexBuffer length] / sizeof(MBEIndex)
                          indexType:MBEIndexType
                        indexBuffer:self.mesh.indexBuffer
                  indexBufferOffset:0];

  [renderPass endEncoding];
  
  [commandBuffer presentDrawable:view.currentDrawable];
  
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
    self.bufferIndex = (self.bufferIndex + 1) % MBEInFlightBufferCount;
    dispatch_semaphore_signal(self.displaySemaphore);
  }];
  
  [commandBuffer commit];
}

- (void)makeDevice {
  _device = MTLCreateSystemDefaultDevice();
}

- (void)makeResources {
  MBETextureLoader *textureLoader = [MBETextureLoader new];
  self.diffuseTexture = [textureLoader texture2DWithImageNamed:@"spot_texture" mipmapped:YES commandQueue:self.commandQueue];
  
  NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"spot" withExtension:@"obj"];
  MBEOBJModel *model = [[MBEOBJModel alloc] initWithContentsOfURL:modelURL generateNormals:YES];
  MBEOBJGroup *group = [model groupForName:@"spot"];
  self.mesh = [[MBEOBJMesh alloc] initWithGroup:group device:self.device];
  self.uniformBuffer = [self.device newBufferWithLength:sizeof(MBEUniforms) * MBEInFlightBufferCount
                                                options:MTLResourceOptionCPUCacheModeDefault];
  self.uniformBuffer.label = @"Uniforms";
  
  MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
  samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
  samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
  samplerDesc.minFilter = MTLSamplerMinMagFilterNearest;
  samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
  samplerDesc.mipFilter = MTLSamplerMipFilterLinear;
  self.samplerState = [self.device newSamplerStateWithDescriptor:samplerDesc];
}

- (void)makePipeline {
  id<MTLLibrary> library = [self.device newDefaultLibrary];
  id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertex_project"];
  id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragment_texture"];
  
  MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
  pipelineDescriptor.vertexFunction = vertexFunc;
  pipelineDescriptor.fragmentFunction = fragmentFunc;
  pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
  
  MTLDepthStencilDescriptor *depthStencilDescriptor = [MTLDepthStencilDescriptor new];
  depthStencilDescriptor.depthCompareFunction = MTLCompareFunctionLess;
  depthStencilDescriptor.depthWriteEnabled = YES;
  self.depthStencilState = [self.device newDepthStencilStateWithDescriptor:depthStencilDescriptor];

  NSError *error = nil;
  self.pipeline = [self.device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                              error:&error];
  
  if (!self.pipeline) {
    NSLog(@"Error occurred when creating render pipeline state: %@", error);
  }
  
  self.commandQueue = [self.device newCommandQueue];
}

@end
