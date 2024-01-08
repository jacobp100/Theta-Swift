//
//  ContentView.swift
//  Theta
//
//  Created by Jacob Parker on 02/01/2024.
//

import SwiftUI
import UIKit
import MetalKit

class GraphView: MTKView, MTKViewDelegate {
    var equation: String? { didSet { if equation != oldValue { resetPipelineState() } } }
    @Invalidating(.display) var origin: CGPoint = .zero
    @Invalidating(.display) var scale: CGFloat = 1

    private var graphLib: MTLLibrary?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        self.delegate = self
        self.enableSetNeedsDisplay = true
        self.autoResizeDrawable = true

        guard let device, device.supportsFunctionPointers else {
            return
        }

        self.commandQueue = device.makeCommandQueue()

        if let graphURL = Bundle.main.url(forResource: "Graph", withExtension: "metallib"),
           let graphLib = try? device.makeLibrary(URL: graphURL) {
            self.graphLib = graphLib
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        self.setNeedsDisplay()
    }

    func resetPipelineState() {
        self.pipelineState = nil
        setNeedsDisplay()
    }

    func buildPipelineStateIfNeeded() -> MTLRenderPipelineState? {
        if let pipelineState {
            return pipelineState
        }

        guard let equation,
              let device,
              let graphLib else {
            return nil
        }

        let source = """
            #include <metal_stdlib>
            using namespace metal;

            [[visible]] float eq(float x, float y) {
                return y - (\(equation));
            }
        """

        let sourceCompileOptions = MTLCompileOptions()
        sourceCompileOptions.fastMathEnabled = false
        guard let library = try? device.makeLibrary(source: source, options: sourceCompileOptions),
              let eq = library.makeFunction(name: "eq") else {
            print("Failed to build library")
            return nil
        }

        let linkedFunctions = MTLLinkedFunctions()
        linkedFunctions.functions = [eq]

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = graphLib.makeFunction(name: "graphVertex")
        pipelineDescriptor.fragmentFunction = graphLib.makeFunction(name: "graphFragment")
        pipelineDescriptor.fragmentLinkedFunctions = linkedFunctions;
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            print("Failed to build pipeline state")
            return nil
        }

        self.pipelineState = pipelineState

        return pipelineState
    }

    func draw(in view: MTKView) {
        guard let device,
              let currentRenderPassDescriptor,
              let currentDrawable,
              let commandQueue,
              let pipelineState = buildPipelineStateIfNeeded(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor)!

        commandEncoder.setRenderPipelineState(pipelineState)

        let pixelScale = window?.screen.scale ?? 1
        var offset = (Float(origin.x * pixelScale), Float(origin.y * pixelScale))
        let offsetBuffer = device.makeBuffer(bytes: &offset,
                                             length: MemoryLayout<(Float, Float)>.stride)!
        commandEncoder.setFragmentBuffer(offsetBuffer, offset: 0, index: 1)

        var scale = Float(scale * 50)
        let scaleBuffer = device.makeBuffer(bytes: &scale,
                                            length: MemoryLayout<Float>.stride)!
        commandEncoder.setFragmentBuffer(scaleBuffer, offset: 0, index: 2)

        var size = (Float(drawableSize.width), Float(drawableSize.height))
        let sizeBuffer = device.makeBuffer(bytes: &size,
                                           length: MemoryLayout<(Float, Float)>.stride)!
        commandEncoder.setFragmentBuffer(sizeBuffer, offset: 0, index: 3)

        commandEncoder.drawPrimitives(type: .triangle,
                                      vertexStart: 0,
                                      vertexCount: 6)

        commandEncoder.endEncoding()

        commandBuffer.present(currentDrawable)

        commandBuffer.commit()
    }
}

class ScrollableGraphView: GraphView, UIGestureRecognizerDelegate {
    override init() {
        super.init()

        let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        panGestureRecognizer.allowedScrollTypesMask = .all
        panGestureRecognizer.delegate = self
        addGestureRecognizer(panGestureRecognizer)

        let pinchGestureRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:)))
        pinchGestureRecognizer.delegate = self
        addGestureRecognizer(pinchGestureRecognizer)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, 
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc func didPan(_ sender: UIPanGestureRecognizer) {
        guard sender.state == .changed else { return }
        let translation = sender.translation(in: self)
        origin = CGPoint(x: origin.x + translation.x,
                         y: origin.y + translation.y)
        sender.setTranslation(.zero, in: self)
    }

    @objc func didPinch(_ sender: UIPinchGestureRecognizer) {
        guard sender.state == .changed else { return }
        scale *= sender.scale
        sender.scale = 1
    }
}

struct Graph: UIViewRepresentable {
    let equation: String?

    func makeUIView(context: Context) -> ScrollableGraphView {
        let uiView = ScrollableGraphView()
        uiView.equation = equation
        return uiView
    }

    func updateUIView(_ uiView: ScrollableGraphView, context: Context) {
        uiView.equation = equation
    }
}

struct ContentView: View {
    @State var editingEquation = "10 * sin(x) / x"
    @State var equation: String?

    func render() {
        equation = editingEquation
    }

    var body: some View {
        VStack {
            TextField("Function", text: $editingEquation)
                .onSubmit(render)

            Graph(equation: equation)
                .onAppear(perform: render)
        }
    }
}

#Preview {
    ContentView()
}
