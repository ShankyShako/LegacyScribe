import ComposableArchitecture
import Dependencies
import IdentifiedCollections
import SwiftUI

public struct ModelInfo: Equatable, Identifiable {
	public let name: String
	public var isDownloaded: Bool

	public var id: String { name }

	public init(name: String, isDownloaded: Bool) {
		self.name = name
		self.isDownloaded = isDownloaded
	}
}

@Reducer
public struct ModelDownloadFeature {
	@ObservableState
	public struct State {
		@Shared(.hexSettings) var hexSettings: HexSettings

		// List of all known models from getAvailableModels()
		public var availableModels: IdentifiedArrayOf<ModelInfo> = []

		// The recommended "default" from whisperKit
		public var recommendedModel: String = ""

		// Current download / progress states
		public var isDownloading: Bool = false
		public var downloadProgress: Double = 0
		public var downloadError: String?
		public var downloadingModelName: String?

		public init() {}
	}

	public enum Action: BindableAction {
		case binding(BindingAction<State>)

		case fetchModels
		case fetchModelsResponse(String, [ModelInfo])

		case selectModel(String)

		case downloadSelectedModel
		case downloadProgress(Double)
		case downloadResponse(Result<String, Error>)

		case deleteSelectedModel
	}

	@Dependency(\.transcription) var transcription

	public init() {}

	public var body: some ReducerOf<Self> {
		BindingReducer()

		Reduce { state, action in
			switch action {
			case .binding:
				return .none

			// 1) Load the recommended model + the list of all available model names
			case .fetchModels:
				return .run { send in
					do {
						let recommended = try await transcription.getRecommendedModels().default
						let names = try await transcription.getAvailableModels()

						// Mark each model as downloaded or not
						var list = [ModelInfo]()
						for modelName in names {
							let downloaded = await transcription.isModelDownloaded(modelName)
							list.append(ModelInfo(name: modelName, isDownloaded: downloaded))
						}

						await send(.fetchModelsResponse(recommended, list))
					} catch {
						await send(.fetchModelsResponse("", []))
					}
				}

			case let .fetchModelsResponse(recommended, list):
				state.recommendedModel = recommended
				state.availableModels = IdentifiedArrayOf(uniqueElements: list)
				return .none

			// 2) The user picks a new model => update & check if downloaded
			case let .selectModel(newModel):
				state.$hexSettings.withLock { $0.selectedModel = newModel }
				return .none

			// 3) Download the currently selected model
			case .downloadSelectedModel:
				let model = state.hexSettings.selectedModel
				guard !model.isEmpty else { return .none }

				state.isDownloading = true
				state.downloadProgress = 0
				state.downloadError = nil
				state.downloadingModelName = model

				return .run { send in
					do {
						// Start the download & track progress
						try await transcription.downloadModel(model) { prog in
							Task { await send(.downloadProgress(prog.fractionCompleted)) }
						}
						await send(.downloadResponse(.success(model)))
					} catch {
						await send(.downloadResponse(.failure(error)))
					}
				}

			// 4) Delete the currently selected model
			case .deleteSelectedModel:
				let model = state.hexSettings.selectedModel
				guard !model.isEmpty else { return .none }
				
				return .run { send in
					do {
						try await transcription.deleteModel(model)
						// After deletion, reload the model list to get accurate download statuses
						await send(.fetchModels)
					} catch {
						await send(.downloadResponse(.failure(error)))
					}
				}

			case let .downloadProgress(value):
				state.downloadProgress = value
				return .none

			case let .downloadResponse(.success(modelName)):
				state.isDownloading = false
				state.downloadProgress = 1
				state.downloadError = nil
				state.downloadingModelName = nil

				// Mark it as downloaded in the list
				state.availableModels[id: modelName]?.isDownloaded = true
				return .none

			case let .downloadResponse(.failure(err)):
				state.isDownloading = false
				state.downloadError = err.localizedDescription
				state.downloadProgress = 0
				state.downloadingModelName = nil
				return .none
			}
		}
	}
}

struct ModelDownloadView: View {
	@Bindable var store: StoreOf<ModelDownloadFeature>

	var body: some View {
		if store.availableModels.isEmpty {
			Text("No models found.").foregroundColor(.secondary)
		} else {
			Picker("Selected Model", selection: Binding(
				get: { store.hexSettings.selectedModel },
				set: { store.send(.selectModel($0)) }
			)) {
				ForEach(store.availableModels) { info in
					let isRecommended = info.name == store.recommendedModel
					let name = isRecommended ? "\(info.name) (Recommended)" : info.name
					HStack {
						Text(name)
						if info.isDownloaded {
							Spacer()
							Image(systemName: "checkmark.circle.fill")
								.foregroundColor(.green)
						}
					}
					.tag(info.name)
				}
			}
		}

		if let error = store.downloadError {
			Text("Download Error: \(error)")
				.foregroundColor(.red)
		}

		// If we are downloading the currently selected model, show progress
		if store.isDownloading,
		   let downloadingName = store.downloadingModelName,
		   downloadingName == store.hexSettings.selectedModel
		{
			VStack(alignment: .leading) {
				Text("Downloading \(downloadingName)...")
				ProgressView(value: store.downloadProgress, total: 1.0)
					.tint(.blue)
					.padding(.vertical, 4)
			}
		} else {
			// Show Delete button if model is downloaded
			if let selectedInfo = store.availableModels
				.first(where: { $0.name == store.hexSettings.selectedModel }),
				selectedInfo.isDownloaded
			{
				Button(role: .destructive, action: {
					store.send(.deleteSelectedModel)
				}) {
					Text("Delete Selected Model")
				}
			}
			// Show Download button if not downloaded yet
			if let selectedInfo = store.availableModels
				.first(where: { $0.name == store.hexSettings.selectedModel }),
				!selectedInfo.isDownloaded
			{
				Button("Download Selected Model") {
					store.send(.downloadSelectedModel)
				}
			}
		}
	}
}
