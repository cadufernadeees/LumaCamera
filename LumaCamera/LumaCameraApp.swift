import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers

@main
struct LumaCameraApp: App {
    var body: some Scene { WindowGroup { CameraScreen() .preferredColorScheme(.dark) } }
}

@MainActor
final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var authorized = false
    @Published var running = false
    @Published var zoom: CGFloat = 1
    @Published var portrait = false
    @Published var smart = true
    @Published var rawSim = false
    @Published var latest: UIImage?
    @Published var busy = false
    @Published var message: String?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.luma.camera.session")
    private var device: AVCaptureDevice?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in DispatchQueue.main.async { self?.authorized = ok; if ok { self?.configure() } } }
        default: message = "Ative o acesso à câmera em Ajustes para fotografar."
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }
    private func configure() {
        guard !session.isRunning else { return }
        authorized = true
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.beginConfiguration(); self.session.sessionPreset = .photo
            guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: cam), self.session.canAddInput(input) else { self.session.commitConfiguration(); return }
            self.device = cam; self.session.addInput(input)
            let output = AVCapturePhotoOutput()
            if self.session.canAddOutput(output) { self.session.addOutput(output); self.photoOutput = output }
            self.session.commitConfiguration(); self.session.startRunning()
            DispatchQueue.main.async { self.running = true }
        }
    }
    private var photoOutput: AVCapturePhotoOutput?
    func setZoom(_ value: CGFloat) {
        zoom = value
        guard let device else { return }
        queue.async { try? device.lockForConfiguration(); device.videoZoomFactor = min(max(value, 1), device.activeFormat.videoMaxZoomFactor); device.unlockForConfiguration() }
    }
    func capture() {
        guard let photoOutput, !busy else { return }
        busy = true; message = nil
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.heic])
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { Task { @MainActor in self.busy = false; self.message = "Não foi possível capturar a foto." }; return }
        Task { @MainActor in
            let result = await self.process(image)
            self.latest = result; self.busy = false
            if self.rawSim { self.saveTIFF(result) }
            else { self.savePhoto(result) }
        }
    }
    private func process(_ image: UIImage) async -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        var output = input
        if smart {
            let color = CIFilter.colorControls(); color.inputImage = output; color.saturation = 1.08; color.contrast = 1.04; color.brightness = 0.005
            if let adjusted = color.outputImage { let sharpen = CIFilter.sharpenLuminance(); sharpen.inputImage = adjusted; sharpen.sharpness = 0.32; output = sharpen.outputImage ?? adjusted }
        }
        if portrait {
            let request = VNGeneratePersonSegmentationRequest(); request.qualityLevel = .accurate; request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(ciImage: input, orientation: .up)
            if (try? handler.perform([request])) != nil, let mask = request.results?.first?.pixelBuffer {
                let maskImage = CIImage(cvPixelBuffer: mask).oriented(.downMirrored).transformed(by: CGAffineTransform(scaleX: output.extent.width / CGFloat(CVPixelBufferGetWidth(mask)), y: output.extent.height / CGFloat(CVPixelBufferGetHeight(mask))))
                let blur = CIFilter.gaussianBlur(); blur.inputImage = input; blur.radius = 12
                let blend = CIFilter.blendWithMask(); blend.inputImage = output; blend.backgroundImage = blur.outputImage?.cropped(to: output.extent); blend.maskImage = maskImage
                output = blend.outputImage ?? output
            }
        }
        guard let cg = context.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
    private func savePhoto(_ image: UIImage) { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil); message = "Foto salva em Fotos" }
    private func saveTIFF(_ image: UIImage) {
        guard let cg = image.cgImage else { savePhoto(image); return }
        let data = NSMutableData(); guard let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else { savePhoto(image); return }
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyTIFFSoftware as String: "Luma Camera · ProRAW simulado", kCGImagePropertyTIFFImageDescription as String: "Imagem computacional editável. Não é Apple ProRAW nem dado RAW do sensor."] as CFDictionary)
        CGImageDestinationFinalize(dest)
        PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data as Data, options: nil) } completionHandler: { [weak self] ok, _ in DispatchQueue.main.async { self?.message = ok ? "TIFF editável salvo em Fotos" : "Falha ao salvar TIFF" } }
    }
}

struct CameraScreen: View {
    @StateObject private var model = CameraModel()
    @State private var showPhoto = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.authorized { CameraPreview(session: model.session).ignoresSafeArea() }
            else { VStack(spacing: 12) { Image(systemName: "camera.fill").font(.system(size: 38)); Text("Sua câmera, com mais controle"); Text("Permita o acesso à câmera para começar.").font(.footnote).foregroundStyle(.white.opacity(0.65)) }.padding() }
            LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack { VStack(alignment: .leading, spacing: 3) { Text("LUMA").font(.system(size: 14, weight: .black, design: .rounded)).tracking(3); Text("CAMERA COMPUTACIONAL").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.white.opacity(0.62)) }; Spacer(); Button { model.rawSim.toggle() } label: { Text(model.rawSim ? "RAW* · ON" : "RAW* · OFF").font(.system(size: 11, weight: .bold, design: .monospaced)).padding(.horizontal, 13).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(model.rawSim ? 0.7 : 0.2))) } }
                    .padding(.horizontal, 24).padding(.top, 16)
                Spacer()
                if model.portrait { Label("RETRATO COMPUTACIONAL", systemImage: "person.crop.rectangle").font(.system(size: 10, weight: .bold)).tracking(1.2).padding(.horizontal, 14).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 16) }
                HStack(spacing: 11) { ForEach([1.0, 1.5, 2.0, 3.0], id: \.self) { n in Button { model.setZoom(n) } label: { Text(n == 1 ? "1×" : "\(n, specifier: "%.1f")×").font(.system(size: 13, weight: model.zoom == n ? .bold : .medium, design: .rounded)).foregroundStyle(model.zoom == n ? .black : .white).frame(width: 42, height: 42).background(model.zoom == n ? Color.white : Color.black.opacity(0.35), in: Circle()) } } }.padding(.bottom, 24)
                HStack(alignment: .center) {
                    Button { if model.latest != nil { showPhoto = true } } label: { Group { if let latest = model.latest { Image(uiImage: latest).resizable().scaledToFill() } else { RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.15)).overlay(Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.white.opacity(0.8))) } }.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.7), lineWidth: 1)) }
                    Spacer()
                    Button { model.capture() } label: { Circle().fill(.white).frame(width: 72, height: 72).overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 3).padding(5)).overlay { if model.busy { ProgressView().tint(.black) } } }.disabled(model.busy)
                    Spacer()
                    Button { model.smart.toggle() } label: { Image(systemName: model.smart ? "sparkles" : "sparkle").font(.system(size: 20, weight: .medium)).frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(model.smart ? .white.opacity(0.8) : .clear)) }
                }.padding(.horizontal, 34)
                HStack { Button { model.portrait.toggle() } label: { Label(model.portrait ? "Retrato" : "Foto", systemImage: model.portrait ? "person.crop.rectangle" : "camera").foregroundStyle(model.portrait ? .white : .white.opacity(0.65)) }; Spacer(); Text("iPhone 14 · 1×–3× digital").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.58)); Spacer(); Text("Auto").foregroundStyle(.white.opacity(0.65)) }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 30).padding(.top, 19)
                if let message = model.message { Text(message).font(.caption).padding(.top, 10).foregroundStyle(.white.opacity(0.8)) }
                if model.rawSim { Text("* TIFF processado — não contém dados RAW do sensor").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).padding(.top, 7) }
            }.padding(.bottom, 22)
        }.onAppear { model.start() }
        .sheet(isPresented: $showPhoto) {
            if let latest = model.latest { Image(uiImage: latest).resizable().scaledToFit().background(.black).presentationDetents([.large]) }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let v = PreviewView(); v.previewLayer.session = session; v.previewLayer.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ view: PreviewView, context: Context) { view.previewLayer.session = session }
}
final class PreviewView: UIView { override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }; var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer } }

