//
//  PopUpViewController.swift
//  Notification Agent
//
//  Created by Jan Valentik on 18/06/2021.
//  Copyright © 2021 IBM Inc. All rights reserved
//  SPDX-License-Identifier: Apache2.0
//
//  swiftlint:disable function_body_length type_body_length

import Cocoa
import os.log
import Foundation
import SwiftyMarkdown

class PopUpViewController: NSViewController {

    // MARK: - Static variables

    static var identifier: NSStoryboard.SceneIdentifier = .init(stringLiteral: "popUpViewController")

    // MARK: - Outlets

    @IBOutlet weak var iconView: NSImageView!
    @IBOutlet weak var helpButton: NSButton!
    @IBOutlet weak var mainButton: NSButton!
    @IBOutlet weak var secondaryButton: NSButton!
    @IBOutlet weak var tertiaryButton: NSButton!
    @IBOutlet weak var popupElementsStackView: NSStackView!

    // MARK: - Variables

    var notificationObject: NotificationObject!
    var timeoutTimer: Timer?
    var replyHandler = ReplyHandler.shared
    let context = Context.main
    var shouldAllowCancel: Bool = false {
        didSet {
            DispatchQueue.main.async {
                self.mainButton.title = self.shouldAllowCancel ? "cancel_label".localized : self.notificationObject.mainButton.label
            }
        }
    }
    var accessoryViews: [AccessoryView] = []

    // MARK: - Instance methods
    
    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.level = (notificationObject?.alwaysOnTop ?? false) ? .floating : .normal
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    // MARK: - Private methods

    /// Configure the popup's window.
    private func configureView() {
        configureWindow()
        configureMainLabels()
        setIconIfNeeded()
        configureButtons()

        for accessoryView in notificationObject?.accessoryViews?.reversed() ?? [] {
            configureAccessoryView(accessoryView)
        }

        checkStackViewLayout()
        setTimeoutIfNeeded()
        checkButtonVisibility()
        configureAccessibilityElements()
    }

    /// Configure the bar title and the level for the popup's window.
    private func configureWindow() {
        self.title = notificationObject?.barTitle
    }

    /// Set the title and the description of the popup if defined.
    private func configureMainLabels() {
        if let title = notificationObject?.title {
            let titleLabel = NSTextField(wrappingLabelWithString: title.localized)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.setAccessibilityLabel("popup_accessibility_label_title".localized)
            if let fontSize = titleLabel.font?.pointSize {
                titleLabel.font = .boldSystemFont(ofSize: fontSize)
            }
            self.popupElementsStackView.insertView(titleLabel, at: 0, in: .top)
        }
        if let subtitle = notificationObject?.subtitle {
            let maxSubtitleHeight: CGFloat = !(notificationObject.accessoryViews?.isEmpty ?? true) ? 200 : 450
            let textView = MarkdownTextView(withText: subtitle.localized, maxViewHeight: maxSubtitleHeight)
            textView.setAccessibilityLabel("popup_accessibility_label_subtitle".localized)
            self.popupElementsStackView.insertView(textView, at: 0, in: .center)
        }
    }

    /// This method load and set the icon if a custom one was defined.
    private func setIconIfNeeded() {
        func loadIcon(from filePath: String) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
               let image = NSImage(data: data) {
                iconView.image = image
            }
        }
        if let iconPath = notificationObject.iconPath,
           FileManager.default.fileExists(atPath: iconPath) {
            loadIcon(from: iconPath)
        } else {
            iconView.image = NSImage(named: NSImage.Name("default_icon"))
        }
    }
    
    /// Set the needed buttons in the popup's window.
    private func configureButtons() {
        self.helpButton.isHidden = notificationObject?.helpButton == nil
        
        let defaultTitle = ConfigurableParameters.defaultMainButtonLabel
        self.mainButton.title = notificationObject?.mainButton.label.localized ?? defaultTitle
        
        if let secondaryButtonLabel = notificationObject?.secondaryButton?.label {
            self.secondaryButton.isHidden = false
            self.secondaryButton.title = secondaryButtonLabel.localized
        }
        
        if let tertiaryButtonLabel = notificationObject?.tertiaryButton?.label {
            self.tertiaryButton.isHidden = false
            self.tertiaryButton.title = tertiaryButtonLabel.localized
        }
    }
    
    /// Configure and insert the related accessory view.
    /// - Parameter accessoryView: the defined accessory view.
    private func configureAccessoryView(_ accessoryView: NotificationAccessoryElement) {
        switch accessoryView.type {
        case .timer:
            guard let rawTime = notificationObject.timeout,
                  let time = Int(rawTime) else { return }
            let timerAccessoryView = TimerAccessoryView(withTimeInSeconds: time, label: accessoryView.payload ?? "")
            timerAccessoryView.translatesAutoresizingMaskIntoConstraints = false
            timerAccessoryView.timerDelegate = self
            self.popupElementsStackView.insertView(timerAccessoryView, at: 0, in: .bottom)
        case .whitebox:
            let markdownTextView = MarkdownTextView(withText: accessoryView.payload ?? "", drawsBackground: true)
            self.popupElementsStackView.insertView(markdownTextView, at: 0, in: .bottom)
        case .progressbar:
            let progressBarAccessoryView = ProgressBarAccessoryView(accessoryView.payload)
            self.popupElementsStackView.insertView(progressBarAccessoryView, at: 0, in: .bottom)
            progressBarAccessoryView.progressBarDelegate = self
            progressBarAccessoryView.delegate = self
            self.accessoryViews.append(progressBarAccessoryView)
            self.shouldAllowCancel = progressBarAccessoryView.isUserInterruptionAllowed
        case .image:
            guard let media = accessoryView.media, media.image != nil else { return }
            let imageAccessoryView = ImageAccessoryView(with: media)
            self.popupElementsStackView.insertView(imageAccessoryView, at: 0, in: .bottom)
        case .video:
            guard let media = accessoryView.media, media.player != nil else { return }
            let videoAccessoryView = VideoAccessoryView(with: media)
            videoAccessoryView.delegate = self
            self.popupElementsStackView.insertView(videoAccessoryView, at: 0, in: .bottom)
        case .input, .securedinput, .secureinput:
            do {
                let inputAccessoryView = try InputAccessoryView(with: accessoryView.payload ?? "", isSecure: accessoryView.type == .securedinput || accessoryView.type == .secureinput)
                inputAccessoryView.delegate = self
                self.popupElementsStackView.insertView(inputAccessoryView, at: 0, in: .bottom)
                self.accessoryViews.append(inputAccessoryView)
            } catch {
                NALogger.shared.log("Error while creating accessory view: %{public}@", [error.localizedDescription])
            }
        case .dropdown:
            do {
                let dropDownAccessoryView = try DropDownAccessoryView(with: accessoryView.payload ?? "")
                self.popupElementsStackView.insertView(dropDownAccessoryView, at: 0, in: .bottom)
                dropDownAccessoryView.delegate = self
                self.accessoryViews.append(dropDownAccessoryView)
            } catch {
                NALogger.shared.log("Error while creating accessory view: %{public}@", [error.localizedDescription])
            }
        case .html:
            let htmlAccessoryView = HTMLAccessoryView(withText: accessoryView.payload ?? "", drawsBackground: false)
            self.popupElementsStackView.insertView(htmlAccessoryView, at: 0, in: .bottom)
        case .htmlwhitebox:
            let htmlAccessoryView = HTMLAccessoryView(withText: accessoryView.payload ?? "", drawsBackground: true)
            self.popupElementsStackView.insertView(htmlAccessoryView, at: 0, in: .bottom)
        case .checklist:
            do {
                let checklistAccessoryView = try CheckListAccessoryView(with: accessoryView.payload ?? "")
                self.popupElementsStackView.insertView(checklistAccessoryView, at: 0, in: .bottom)
                checklistAccessoryView.delegate = self
                self.accessoryViews.append(checklistAccessoryView)
            } catch {
                NALogger.shared.log("Error while creating accessory view: %{public}@", [error.localizedDescription])
            }
        }
    }

    /// Check the stack view distribution based on the number of the arrangedSubviews.
    private func checkStackViewLayout() {
        if self.popupElementsStackView.arrangedSubviews.count == 1 {
            self.popupElementsStackView.distribution = .equalSpacing
        } else {
            self.popupElementsStackView.distribution = .gravityAreas
        }
    }

    /// If needed to set a timeout for the popup this method set the related actions and fire a timer.
    private func setTimeoutIfNeeded() {
        for accessoryView in notificationObject.accessoryViews ?? [] {
            guard accessoryView.type != .timer else { return }
        }
        if let timeoutString = notificationObject?.timeout, let timeout = Int(timeoutString) {
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout),
                                                repeats: false, block: { [weak self] _ in
                                                    self?.triggerAction(ofType: .timeout)
            })
        } 
    }
    
    private func checkButtonVisibility() {
        var mainButtonState: AccessoryView.ButtonState = .enabled
        var secondaryButtonState: AccessoryView.ButtonState = .enabled
        
        for accessoryView in accessoryViews {
            switch accessoryView.mainButtonState {
            case .disabled, .hidden:
                guard mainButtonState != .hidden else { continue }
                mainButtonState = accessoryView.mainButtonState
            case .enabled:
                continue
            }
        }
        switch mainButtonState {
        case .disabled:
            self.mainButton.isHidden = false
            self.mainButton.isEnabled = false
        case .hidden:
            self.mainButton.isHidden = true
        case .enabled:
            self.mainButton.isHidden = false
            self.mainButton.isEnabled = true
        }
        guard notificationObject.secondaryButton != nil else { return }
        for accessoryView in accessoryViews {
            switch accessoryView.secondaryButtonState {
            case .disabled, .hidden:
                guard secondaryButtonState != .hidden else { continue }
                secondaryButtonState = accessoryView.secondaryButtonState
            case .enabled:
                break
            }
        }
        switch secondaryButtonState {
        case .disabled:
            self.secondaryButton.isHidden = false
            self.secondaryButton.isEnabled = false
        case .hidden:
            self.secondaryButton.isHidden = true
        case .enabled:
            self.secondaryButton.isHidden = false
            self.secondaryButton.isEnabled = true
        }
    }

    /// Invalidate and delete the existing timer.
    private func resetTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    /// Close the popup window.
    private func closeWindow() {
        resetTimer()
        view.window?.close()
    }

    private func triggerAction(ofType type: UserReplyType) {
        defer {
            DispatchQueue.global(qos: .background).async {
                self.replyHandler.handleResponse(ofType: type, for: self.notificationObject)
            }
        }
        switch type {
        case .main, .secondary, .timeout:
            DispatchQueue.main.async {
                self.closeWindow()
            }
        default:
            break
        }
    }
    
    private func configureAccessibilityElements() {
        self.mainButton.setAccessibilityLabel("\("popup_accessibility_button_main".localized). \(self.mainButton.isEnabled ? "" : "popup_accessibility_button_disabled".localized)")
        self.secondaryButton.setAccessibilityLabel("popup_accessibility_button_secondary".localized)
        self.tertiaryButton.setAccessibilityLabel("popup_accessibility_button_tertiary".localized)
        self.helpButton.setAccessibilityLabel("popup_accessibility_button_info".localized)
        self.iconView.setAccessibilityLabel("popup_accessibility_image_left".localized)
        self.popupElementsStackView.setAccessibilityLabel("popup_accessibility_stackview_body".localized)
    }

    // MARK: - Actions

    /// User clicked the main button.
    @IBAction func didClickedMainButton(_ sender: NSButton) {
        for accessoryView in accessoryViews.reversed() {
            switch accessoryView.self {
            case is InputAccessoryView:
                if let value = (accessoryView as? InputAccessoryView)?.inputValue {
                    print(value)
                }
            case is DropDownAccessoryView:
                if let value = (accessoryView as? DropDownAccessoryView)?.selectedItem {
                    print(value)
                }
            case is CheckListAccessoryView:
                if let needsCompletion = (accessoryView as? CheckListAccessoryView)?.needCompletion,
                   !needsCompletion,
                   let value = (accessoryView as? CheckListAccessoryView)?.selectedIndexes {
                    var output = ""
                    value.forEach({ output += "\($0.description) "})
                    print(output.trimmingCharacters(in: .whitespaces))
                }
            default:
                break
            }
        }
        self.triggerAction(ofType: shouldAllowCancel ? .cancel : .main)
    }

    /// User clicked the secondary button.
    @IBAction func didClickedSecondaryButton(_ sender: NSButton) {
        self.triggerAction(ofType: .secondary)
    }

    /// User clicked the tertiary button.
    @IBAction func didClickedTertiaryButton(_ sender: NSButton) {
        self.triggerAction(ofType: .tertiary)
    }

    /// User clicked the help button.
    @IBAction func didClickedHelpButton(_ sender: NSButton) {
        guard let helpButtonObject = notificationObject?.helpButton else { return }
        switch helpButtonObject.callToActionType {
        case .infopopup:
            let infos = InfoSection(fields: [InfoField(label: helpButtonObject.callToActionPayload)])
            let infoPopupViewController = InfoPopOverViewController(with: infos)
            self.present(infoPopupViewController,
                         asPopoverRelativeTo: sender.convert(sender.bounds, to: self.view),
                         of: self.view,
                         preferredEdge: .maxX,
                         behavior: .semitransient)
        default:
            self.triggerAction(ofType: .help)
        }
    }
}

// MARK: - TimerAccessoryViewDelegate methods implementation.
extension PopUpViewController: TimerAccessoryViewDelegate {
    func timerDidFinished(_ sender: TimerAccessoryView) {
        self.triggerAction(ofType: .timeout)
    }
}

// MARK: - ProgressBarAccessoryViewDelegate methods implementation.
extension PopUpViewController: ProgressBarAccessoryViewDelegate {
    func didChangeEstimation(_ isIndeterminated: Bool) {
        if isIndeterminated {
            self.mainButton.title = notificationObject.mainButton.label
            self.secondaryButton.isHidden = notificationObject.secondaryButton != nil ? false : true
        } else {
            self.mainButton.title = "cancel_label".localized
            self.secondaryButton.isHidden = true
        }
    }
}

// MARK: - AccessoryViewDelegate methods implementation.
extension PopUpViewController: AccessoryViewDelegate {
    func accessoryViewStatusDidChange(_ sender: AccessoryView) {
        self.timeoutTimer?.invalidate()
        self.setTimeoutIfNeeded()
        if let progressBarCompleted = (sender as? ProgressBarAccessoryView)?.progressCompleted, shouldAllowCancel {
            self.shouldAllowCancel = !progressBarCompleted
        }
        checkButtonVisibility()
    }
}
