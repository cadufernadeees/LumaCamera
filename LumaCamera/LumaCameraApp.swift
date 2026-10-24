import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

private let accent = Color(red: 0.96, green: 0.08, blue: 0.16)

@main struct LumaCameraApp: App {
    var body: some Scene { WindowGroup { CameraScreen().preferredColorScheme(.dark).tint(accent) } }
}

enum ShootMode: String, CaseIterable, Identifiable {
    case photo = "FOTO", portrait = "RETRATO", night = "NOITE"
    var id: String { rawValue }
}
enum Lens: String, CaseIterable, Identifiable {
    case ultra = "0,5×", one = "1×", two = "2×", three = "3×"
    var id: String { rawValue }
    var factor: CGFloat { switch self { case .ultra: 0.5; case .one: 1; case .two: 2; case .three: 3 } }
}

@MainActor final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var granted = false
    @Published var running = false
    @Published var busy = false
    @Published var mode: ShootMode = .photo
    @Published var lens: Lens = .one
    @Published var zoom: CGFloat = 1
    @Published var exposure: Float = 0
    @Published var flash = false
    @Published var enhance = true
    @Published var simulatedRaw = false
    @Published var latest: UIImage?
    @Published var note: String?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "luma.session")
    private let ci = CIContext()
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                Task { @MainActor in
                    guard let self else { return }
                    self.granted = allowed
                    if allowed { self.configure() } else { self.note = "Permita acesso à câmera em Ajustes." }
                }
            }
        default: note = "Permita acesso à câmera em Ajustes."
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    private func configure() {
        guard !session.isRunning else { return }
        granted = true
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.note = "Não foi possível iniciar a câmera." }
                return
            }
            self.device = camera
            self.session.addInput(input)
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            self.output.maxPhotoQualityPrioritization = .quality
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.running = true }
        }
    }

    func setZoom(_ value: CGFloat) {
        zoom = value
        if value < 1 { changeCamera(.back, ultra: true); return }
        queue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(max(value, 1), device.activeFormat.videoMaxZoomFactor)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func changeCamera(_ requested: AVCaptureDevice.Position? = nil, ultra: Bool = false) {
        let next = requested ?? (position == .back ? .front : .back)
        queue.async { [weak self] in
            guard let self else { return }
            let kind: AVCaptureDevice.DeviceType = ultra ? .builtInUltraWideCamera : .builtInWideAngleCamera
            guard let camera = AVCaptureDevice.default(kind, for: .video, position: next),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                DispatchQueue.main.async { self.note = "Lente indisponível neste iPhone." }
                return
            }
            self.session.beginConfiguration()
            if let old = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first { self.session.removeInput(old) }
            guard self.session.canAddInput(input) else { self.session.commitConfiguration(); return }
            self.session.addInput(input); self.device = camera; self.position = next
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.lens = ultra ? .ultra : .one; self.zoom = ultra ? 0.5 : 1 }
        }
    }

    func focus(_ p: CGPoint) {
        queue.async { [weak self] in
            guard let device = self?.device, device.isFocusPointOfInterestSupported else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = p
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = p
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func setEV(_ ev: Float) {
        exposure = ev
        queue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                let bias = min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(bias, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func capture() {
        guard running, !busy else { return }
        busy = true; note = nil
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        if flash && output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            Task { @MainActor in self.busy = false; self.note = "Falha na captura. Tente novamente." }; return
        }
        Task { @MainActor in
            let final = await self.process(image)
            self.latest = final
            self.save(final)
        }
    }

    private func process(_ image: UIImage) async -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        var result = input
        let color = CIFilter.colorControls()
        color.inputImage = result; color.saturation = 1.06
        color.contrast = enhance ? 1.04 : 1
        color.brightness = enhance ? 0.005 : 0
        result = color.outputImage ?? result
        if enhance {
            let sharp = CIFilter.sharpenLuminance()
            sharp.inputImage = result; sharp.sharpness = 0.28
            result = sharp.outputImage ?? result
        }
        if mode == .night {
            let nr = CIFilter.noiseReduction()
            nr.inputImage = result; nr.noiseLevel = 0.025; nr.sharpness = 0.35
            result = nr.outputImage ?? result
            let shadows = CIFilter.highlightShadowAdjust()
            shadows.inputImage = result; shadows.shadowAmount = 0.28
            result = shadows.outputImage ?? result
        }
        if mode == .portrait {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(ciImage: input, orientation: .up)
            if (try? handler.perform([request])) != nil, let px = request.results?.first?.pixelBuffer {
                let mask = CIImage(cvPixelBuffer: px)
                let scaled = mask.transformed(by: CGAffineTransform(
                    scaleX: input.extent.width / CGFloat(CVPixelBufferGetWidth(px)),
                    y: input.extent.height / CGFloat(CVPixelBufferGetHeight(px))))
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = input; blur.radius = 13
                let blend = CIFilter.blendWithMask()
                blend.inputImage = result; blend.backgroundImage = blur.outputImage?.cropped(to: input.extent); blend.maskImage = scaled
                result = blend.outputImage ?? result
            }
        }
        guard let cg = ci.createCGImage(result, from: result.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private func save(_ image: UIImage) {
        let data: Data?
        let label: String
        if simulatedRaw, let cg = image.cgImage {
            let buffer = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(buffer, UTType.tiff.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cg, [kCGImagePropertyTIFFSoftware as String: "Luma Camera - RAW simulado"] as CFDictionary)
                data = CGImageDestinationFinalize(destination) ? buffer as Data : nil
                label = "TIFF processado salvo em Fotos (não é RAW do sensor)."
            } else { data = image.jpegData(compressionQuality: 0.96); label = "Foto salva em Fotos." }
        } else { data = image.jpegData(compressionQuality: 0.96); label = "Foto salva em Fotos." }
        guard let data else { busy = false; note = "Erro ao preparar a imagem."; return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        } completionHandler: { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.busy = false
                self?.note = ok ? label : "Confira a permissão de Fotos."
            }
        }
    }

    func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { latest = image } }
    }
}

struct CameraScreen: View {
    @StateObject private var camera = CameraModel()
    @State private var pinchBase: CGFloat = 1
    @State private var focusPosition: CGPoint?
    @State private var viewer = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if camera.granted { CameraPreview(session: camera.session).ignoresSafeArea() }
                LinearGradient(colors: [.black.opacity(0.74), .clear, .clear, .black.opacity(0.86)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(spacing: 0) {
                    header.padding(.horizontal, 22).padding(.top, 8)
                    Spacer()
                    if let focusPosition {
                        RoundedRectangle(cornerRadius: 4).stroke(accent, lineWidth: 1.5).frame(width: 60, height: 60).position(focusPosition)
                    }
                    Spacer()
                    zoomRow.padding(.bottom, 22)
                    shutterRow.padding(.horizontal, 28)
                    modes.padding(.top, 20)
                    controls.padding(.top, 15)
                    if let note = camera.note { Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).padding(.top, 8) }
                }.padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                focusPosition = value.location
                camera.focus(CGPoint(x: value.location.x / geo.size.width, y: value.location.y / geo.size.height))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { focusPosition = nil }
            })
            .simultaneousGesture(MagnificationGesture().onChanged { amount in
                camera.setZoom(min(max(pinchBase * amount, 0.5), 3))
            }.onEnded { amount in
                pinchBase = min(max(pinchBase * amount, 0.5), 3)
                if pinchBase < 1 { camera.changeCamera(.back, ultra: true) }
                else if camera.lens == .ultra { camera.changeCamera(.back) }
            })
            .onAppear { camera.start() }
            .onChange(of: picked) { _, item in camera.importPhoto(item) }
            .sheet(isPresented: $viewer) {
                if let image = camera.latest {
                    ZStack { Color.black.ignoresSafeArea(); Image(uiImage: image).resizable().scaledToFit() }.presentationDetents([.large])
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture").font(.system(size: 27, weight: .semibold)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("LUMA").font(.system(size: 16, weight: .black, design: .rounded)).tracking(3)
                Text("CAMERA PRO").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(accent)
            }
            Spacer()
            Button { camera.flash.toggle() } label: {
                Image(systemName: camera.flash ? "bolt.fill" : "bolt.slash").foregroundStyle(camera.flash ? accent : .white)
                    .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            Button { camera.simulatedRaw.toggle() } label: {
                Text(camera.simulatedRaw ? "RAW*" : "HEIF").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(camera.simulatedRaw ? accent : .white).padding(.horizontal, 11).frame(height: 36)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }.foregroundStyle(.white)
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            ForEach(Lens.allCases) { lens in
                Button {
                    camera.lens = lens
                    camera.setZoom(lens.factor)
                    if lens == .ultra { camera.changeCamera(.back, ultra: true) }
                    else if lens == .one && camera.lens == .ultra { camera.changeCamera(.back) }
                } label: {
                    Text(lens.rawValue).font(.system(size: 12, weight: .bold))
                        .foregroundStyle(camera.lens == lens ? .black : .white)
                        .frame(width: 44, height: 36).background(camera.lens == lens ? accent : .black.opacity(0.5), in: Capsule())
                }
            }
            Text(String(format: "%.1f×", Double(camera.zoom))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var shutterRow: some View {
        HStack {
            PhotosPicker(selection: $picked, matching: .images) {
                Group {
                    if let image = camera.latest { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "photo.on.rectangle").font(.system(size: 20)) }
                }.frame(width: 52, height: 52).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.7)))
            }.onTapGesture(count: 2) { viewer = camera.latest != nil }
            Spacer()
            Button { camera.capture() } label: {
                Circle().fill(.white).frame(width: 76, height: 76)
                    .overlay(Circle().stroke(accent, lineWidth: 3).padding(5))
                    .overlay { if camera.busy { ProgressView().tint(accent) } }
            }.disabled(!camera.running || camera.busy)
            Spacer()
            Button { camera.enhance.toggle() } label: {
                Image(systemName: camera.enhance ? "sparkles" : "sparkle").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(camera.enhance ? accent : .white).frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var modes: some View {
        HStack(spacing: 27) {
            ForEach(ShootMode.allCases) { mode in
                Button { camera.mode = mode } label: {
                    Text(mode.rawValue).font(.system(size: 11, weight: .bold)).tracking(1)
                        .foregroundStyle(camera.mode == mode ? accent : .white.opacity(0.75))
                        .padding(.bottom, 5).overlay(alignment: .bottom) { if camera.mode == mode { Capsule().fill(accent).frame(height: 2) } }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("EV").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(accent)
            Slider(value: Binding(get: { Double(camera.exposure) }, set: { camera.setEV(Float($0)) }), in: -2...2).tint(accent).frame(maxWidth: 140)
            Text(String(format: "%+.1f", camera.exposure)).font(.system(size: 10, design: .monospaced)).frame(width: 32)
            Button { camera.changeCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 42, height: 36).background(.ultraThinMaterial, in: Capsule()) }
        }.foregroundStyle(.white).padding(.horizontal, 18)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session; view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) { view.previewLayer.session = session }
}
private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}