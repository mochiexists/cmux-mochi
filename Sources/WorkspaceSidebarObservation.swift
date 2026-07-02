import Combine
import CmuxCore
import Foundation
import CmuxSidebar

private struct SidebarPanelObservationState: Equatable {
    let panelIds: [UUID]

    init(panels: [UUID: any Panel]) {
        panelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

private struct SidebarImmediateObservationState: Equatable {
    let title: String
    let customDescription: String?
    let isPinned: Bool
    let customColor: String?
    let isPrivacyBlurred: Bool
    let latestConversationMessage: String?
    let latestSubmittedMessage: String?
    let latestSubmittedAt: Date?
}

private struct SidebarObservationState: Equatable {
    let currentDirectory: String
    let extensionSidebarProjectRootPath: String?
    let panels: SidebarPanelObservationState
    let panelDirectories: [UUID: String]
    let isPrivacyBlurred: Bool
    let statusEntries: [String: SidebarStatusEntry]
    let metadataBlocks: [String: SidebarMetadataBlock]
    let logEntries: [SidebarLogEntry]
    let progress: SidebarProgressState?
    let gitBranch: SidebarGitBranchState?
    let panelGitBranches: [UUID: SidebarGitBranchState]
    let pullRequest: SidebarPullRequestState?
    let panelPullRequests: [UUID: SidebarPullRequestState]
    let remoteConfiguration: WorkspaceRemoteConfiguration?
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let remoteConnectionDetail: String?
    let activeRemoteTerminalSessionCount: Int
    let listeningPorts: [Int]
    let browserMediaActivity: BrowserMediaActivity
}

extension Workspace {
    func makeSidebarImmediateObservationPublisher() -> AnyPublisher<Void, Never> {
        let workspaceFields = Publishers.CombineLatest4(
            $title,
            $customDescription,
            $isPinned,
            $customColor
        )
        .combineLatest($isPrivacyBlurred)
        let conversationFields = Publishers.CombineLatest3(
            $latestConversationMessage,
            $latestSubmittedMessage,
            $latestSubmittedAt
        )

        return workspaceFields
            .combineLatest(conversationFields)
            .map { workspaceFields, conversationFields in
                let workspaceValues = workspaceFields.0
                return SidebarImmediateObservationState(
                    title: workspaceValues.0,
                    customDescription: workspaceValues.1,
                    isPinned: workspaceValues.2,
                    customColor: workspaceValues.3,
                    isPrivacyBlurred: workspaceFields.1,
                    latestConversationMessage: conversationFields.0,
                    latestSubmittedMessage: conversationFields.1,
                    latestSubmittedAt: conversationFields.2
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func makeSidebarObservationPublisher() -> AnyPublisher<Void, Never> {
        let workspaceFields = Publishers.CombineLatest4(
            $currentDirectory,
            $extensionSidebarProjectRootPath,
            panelsPublisher.map(SidebarPanelObservationState.init),
            $panelDirectories
        )
        .combineLatest($isPrivacyBlurred)
        let metadataFields = Publishers.CombineLatest4(
            sidebarMetadata.statusEntriesPublisher,
            sidebarMetadata.metadataBlocksPublisher,
            sidebarMetadata.logEntriesPublisher,
            sidebarMetadata.progressPublisher
        )
        let gitFields = Publishers.CombineLatest4(
            sidebarMetadata.gitBranchPublisher,
            sidebarMetadata.panelGitBranchesPublisher,
            sidebarMetadata.pullRequestPublisher,
            sidebarMetadata.panelPullRequestsPublisher
        )
        let remoteFields = Publishers.CombineLatest4(
            $remoteConfiguration,
            $remoteConnectionState,
            $remoteConnectionDetail,
            $activeRemoteTerminalSessionCount
        )

        return Publishers.CombineLatest4(
            workspaceFields,
            metadataFields,
            gitFields,
            remoteFields
        )
            .combineLatest($listeningPorts)
            .compactMap { [weak self] groupedFields, listeningPorts -> SidebarObservationState? in
                guard let self else { return nil }
                let workspaceFields = groupedFields.0
                let workspaceValues = workspaceFields.0
                let metadataFields = groupedFields.1
                let gitFields = groupedFields.2
                let remoteFields = groupedFields.3
                return SidebarObservationState(
                    currentDirectory: workspaceValues.0,
                    extensionSidebarProjectRootPath: workspaceValues.1,
                    panels: workspaceValues.2,
                    panelDirectories: workspaceValues.3,
                    isPrivacyBlurred: workspaceFields.1,
                    statusEntries: metadataFields.0,
                    metadataBlocks: metadataFields.1,
                    logEntries: metadataFields.2,
                    progress: metadataFields.3,
                    gitBranch: gitFields.0,
                    panelGitBranches: gitFields.1,
                    pullRequest: gitFields.2,
                    panelPullRequests: gitFields.3,
                    remoteConfiguration: remoteFields.0,
                    remoteConnectionState: remoteFields.1,
                    remoteConnectionDetail: remoteFields.2,
                    activeRemoteTerminalSessionCount: remoteFields.3,
                    listeningPorts: listeningPorts,
                    browserMediaActivity: self.browserMediaActivity
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
