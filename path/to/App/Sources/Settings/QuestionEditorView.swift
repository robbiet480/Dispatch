# Add a new confirmation dialog for non-lossless conversions
import UIKit

class QuestionEditorView: UIViewController {
    // ...

    private func showConfirmationDialog(for responses: [Response]) {
        // Create a new confirmation dialog for non-lossless conversions
        let alertController = UIAlertController(title: "Confirm Conversion", message: "The following responses will be converted to a new type:", preferredStyle: .alert)

        // Add a table view to display the responses
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.dataSource = self
        alertController.view.addSubview(tableView)

        // Add a confirmation button
        let confirmButton = UIAlertAction(title: "Confirm", style: .default) { [weak self] _ in
            // Apply the conversions
            responses.forEach { $0.type = $0.type }
            self?.updateQuestionType()
        }
        alertController.addAction(confirmButton)

        // Present the confirmation dialog
        present(alertController, animated: true)
    }
}

extension QuestionEditorView: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return responses.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let response = responses[indexPath.row]
        cell.textLabel?.text = response.type.rawValue
        return cell
    }
}