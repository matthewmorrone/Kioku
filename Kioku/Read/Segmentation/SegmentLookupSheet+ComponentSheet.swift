import UIKit

extension SegmentLookupSheet {
    // Presents a nested sheet for a word component stacked over the current lookup sheet.
    // Presented from parentSheet directly so dismissing it returns to the parent sheet unchanged.
    func presentComponentSheet(surface: String, gloss: String?, from parentSheet: UIViewController) {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        vc.additionalSafeAreaInsets.top = 20

        let surfaceLabel = CopyableLabel()
        surfaceLabel.translatesAutoresizingMaskIntoConstraints = false
        surfaceLabel.text = surface
        surfaceLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        surfaceLabel.textAlignment = .center
        surfaceLabel.numberOfLines = 0

        vc.view.addSubview(surfaceLabel)
        NSLayoutConstraint.activate([
            surfaceLabel.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 16),
            surfaceLabel.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            surfaceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: vc.view.leadingAnchor, constant: 16),
            surfaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: vc.view.trailingAnchor, constant: -16),
        ])

        if let gloss, gloss.isEmpty == false {
            let glossLabel = UILabel()
            glossLabel.translatesAutoresizingMaskIntoConstraints = false
            glossLabel.text = gloss
            glossLabel.font = .systemFont(ofSize: 15)
            glossLabel.textColor = .secondaryLabel
            glossLabel.textAlignment = .center
            glossLabel.numberOfLines = 0
            vc.view.addSubview(glossLabel)
            NSLayoutConstraint.activate([
                glossLabel.topAnchor.constraint(equalTo: surfaceLabel.bottomAnchor, constant: 8),
                glossLabel.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 16),
                glossLabel.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
            ])
        }

        vc.modalPresentationStyle = .pageSheet
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
            sheet.largestUndimmedDetentIdentifier = .medium
        }

        parentSheet.present(vc, animated: true)
    }
}
