import SwiftUI

struct CustomShapeView: View {
    @ObservedObject var model: ShapingModel
    @Environment(\.dismiss) private var dismiss

    @State private var down = ""
    @State private var up = ""
    @State private var rtt = ""
    @State private var lossUp = ""
    @State private var lossDown = ""
    @State private var hosts = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Download limit:", text: $down, prompt: Text("2mbit"))
                TextField("Upload limit:", text: $up, prompt: Text("500kbit"))
                TextField("Added round trip, ms:", text: $rtt, prompt: Text("300"))
                TextField("Packet loss up, %:", text: $lossUp, prompt: Text("8"))
                TextField("Packet loss down, %:", text: $lossDown, prompt: Text("0"))
                TextField("Only these hosts:", text: $hosts, prompt: Text("example.com 10.0.0.5"))
            }
            Text("Empty fields stay unlimited. Rates use bit, kbit, mbit, or gbit. Leaving hosts empty shapes the whole machine.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    model.applyCustom(arguments)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasShaping)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var hasShaping: Bool {
        [down, up, rtt, lossUp, lossDown]
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var arguments: [String] {
        var args: [String] = []
        let fields: [(flag: String, value: String)] = [
            ("--down", down), ("--up", up), ("--rtt", rtt),
            ("--loss-up", lossUp), ("--loss-down", lossDown),
        ]
        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { args += [field.flag, value] }
        }
        for host in hosts.split(whereSeparator: { $0 == " " || $0 == "," }) {
            args += ["--host", String(host)]
        }
        return args
    }
}
