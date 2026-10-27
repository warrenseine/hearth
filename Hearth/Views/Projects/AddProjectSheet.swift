import SwiftUI
import HearthKit

struct AddProjectSheet: View {
    var onAdded: (RegisteredProject) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var configFiles = ""
    @State private var envFiles = ""
    @State private var namespaces = ""
    @State private var isImporterPresented = false
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project").font(.title2.weight(.semibold))
            Form {
                LabeledContent("Folder") {
                    HStack {
                        Text(folder?.path ?? "None selected")
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { isImporterPresented = true }
                    }
                }
                TextField("Config files", text: $configFiles, prompt: Text("process-compose.yaml"))
                TextField("Env files", text: $envFiles, prompt: Text(".env (default)"))
                TextField("Namespaces", text: $namespaces, prompt: Text("all"))
            }
            .formStyle(.grouped)
            Text("Comma-separated, relative to the folder. Config files are detected automatically when you choose a folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder == nil || isSaving)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            folder = url
            error = nil
            let detected = ProjectRegistry.discoverConfigFiles(in: url)
            configFiles = detected.joined(separator: ", ")
            if detected.isEmpty { error = "No process-compose.yaml/.yml found in that folder. Enter the config file names." }
        }
        .onAppear { if folder == nil { isImporterPresented = true } }
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func add() async {
        guard let folder else { return }
        isSaving = true
        defer { isSaving = false }
        let files = list(configFiles)
        let result = await environment.store.addProject(
            directory: folder,
            configFiles: files.isEmpty ? nil : files,
            envFiles: list(envFiles),
            namespaces: list(namespaces)
        )
        switch result {
        case .success(let project):
            onAdded(project)
            dismiss()
        case .failure(let failure):
            error = String(describing: failure)
        }
    }
}
