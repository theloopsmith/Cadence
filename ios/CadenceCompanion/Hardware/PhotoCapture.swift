import Foundation
import SwiftUI

#if os(iOS)
import AVFoundation
import UIKit

/// Resizes and compresses a captured frame for upload: longest edge 1280 px,
/// JPEG at 0.8. The backend never stores the image.
public enum PhotoEncoder {
    public static func jpegForUpload(_ image: UIImage, maxEdge: CGFloat = 1280) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1.0
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}

public enum CameraAvailability {
    public static var hasCamera: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
}

/// Presents the system camera and hands back a JPEG ready for upload. Falls
/// back to the photo library on devices without a camera (the Simulator).
public struct CameraPicker: UIViewControllerRepresentable {
    public var onCapture: (Data) -> Void
    public var onCancel: () -> Void

    public init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    public func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        let hasCam = UIImagePickerController.isSourceTypeAvailable(.camera)
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        if hasCam && (status == .authorized || status == .notDetermined) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.cameraDevice = .rear
            picker.showsCameraControls = true
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            }
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    public final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        public func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.originalImage] as? UIImage)
            if let image, let jpeg = PhotoEncoder.jpegForUpload(image) {
                onCapture(jpeg)
            } else {
                onCancel()
            }
        }

        public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
#else
public enum CameraAvailability {
    public static var hasCamera: Bool { false }
}

/// macOS has no camera picker in this package; the tests never present one.
public struct CameraPicker: View {
    public var onCapture: (Data) -> Void
    public var onCancel: () -> Void

    public init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Camera is not available here.")
            Button("Close", action: onCancel)
        }
        .padding()
    }
}
#endif

extension View {
    @ViewBuilder
    public func cameraPresentation(
        isPresented: Binding<Bool>,
        onCapture: @escaping (Data) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            CameraPicker(onCapture: onCapture, onCancel: onCancel)
                .ignoresSafeArea()
        }
        #else
        self.sheet(isPresented: isPresented) {
            CameraPicker(onCapture: onCapture, onCancel: onCancel)
        }
        #endif
    }
}
