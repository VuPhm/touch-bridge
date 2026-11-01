# Nhật Ký Thay Đổi (Changelog)

Toàn bộ các thay đổi đáng chú ý của dự án **TouchBridge** sẽ được ghi chép tại tài liệu này theo quy chuẩn [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) và tuân thủ [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-11-01

### Thêm Mới (Added)
- **Giao diện Cài Đặt Native 4 Tab**:
  - *Tổng quan*: Banner trạng thái lớn trực quan (Sẵn sàng / Cần cấp quyền / Mất kết nối), tóm tắt thiết bị phần cứng, công tắc kích hoạt và Launch at Login.
  - *Cảm ứng*: Tùy chọn Cuộn trực tiếp 1 ngón, kéo thả thông minh kèm bảng hướng dẫn quy tắc thao tác chi tiết.
  - *Màn hình & Hiệu chuẩn*: Hiển thị độ phân giải, hướng xoay (270°), công tắc đảo chiều trục tọa độ 90°/270°, trạng thái profile hiệu chuẩn và nút kích hoạt hiệu chuẩn 4 điểm.
  - *Chẩn đoán & Giới thiệu*: Nút xuất báo cáo chẩn đoán ra Desktop, mở cửa sổ chẩn đoán chi tiết, xem log trong Finder, gọi bàn phím ảo và thông tin bản quyền/GitHub.
- **Menu Bar Tinh Gọn**:
  - Biểu tượng Menu Bar dạng template hỗ trợ hoàn hảo cả Dark Mode và Light Mode.
  - Menu trạng thái 2 dòng ngắn gọn, không dùng từ ngữ kỹ thuật phức tạp.
  - Phím tắt điều khiển nhanh: bật/tắt cảm ứng, mở cài đặt, hiệu chuẩn màn hình, gọi bàn phím ảo, xuất log chẩn đoán và thoát.
- **Khởi Động Cùng Máy Tính (Launch at Login)**: Tích hợp chuẩn `SMAppService.mainApp` cho macOS 13+.
- **Quản Lý Phiên Bản & Đơn Instance (Single-Instance Enforcement)**:
  - Tự động kích hoạt instance đang chạy và thoát an toàn khi người dùng khởi chạy thêm instance thứ hai.
  - Ngăn ngừa tình trạng tranh chấp thiết bị HID IOHIDManager.
- **Tự Động Reset Trạng Thái Khi Sleep/Wake**: Đăng ký nhận thông báo `NSWorkspace.willSleepNotification` và `screensDidSleepNotification` để hủy bỏ tức thì mọi gesture và giải phóng hoàn toàn virtual mouse-down, không bao giờ bị kẹt chuột sau khi mở máy.
- **Fast-Path Drag Tối Ưu Độ Trễ**: Xử lý trực tiếp vùng thanh tiêu đề (Title Bar) và mép đổi kích thước (Resize Edges) với thời gian phản hồi < 0.2ms, bỏ qua duyệt cây Accessibility nặng.
- **Tiếp Quản Tự Nhiên Khi Dùng Chuột Vật Lý**: Lắng nghe sự kiện di chuyển chuột/trackpad trong quá trình cảm ứng để nhường quyền ưu tiên tức thì cho thiết bị vật lý.
- **Bộ Lọc Chống Rung Cuộn Thích Ứng (Adaptive Anti-Shake Scroll Stabilizer)**:
  - Triệt tiêu dao động vi mô (sensor jitter và rung tay $\pm 0.6$ pt) khi ngón tay dừng yên thành đúng 0 delta cuộn.
  - Tích lũy chuyển động subpixel khi vuốt chậm có chủ ý, mang lại cảm giác cuộn mượt mà liên tục, không dính và không giật cục.
  - Chuyển tiếp 1:1 không độ trễ đối với thao tác vuốt nhanh ($> 40$ pt/s).
  - Phản hồi đảo chiều cuộn tức thì không có độ trễ do xả bộ tích lũy ngược dấu ngay trong frame.
  - Triệt tiêu hoàn toàn "đuôi trôi trượt" (trailing slide) khi ngón tay dừng lại trên màn hình.
  - Cơ chế chặn quán tính ngoài ý muốn khi dừng tay trước khi thả (Lift-off stationary dwell gate $\ge 85$ms).
- **Chẩn Đoán Lưới 3×3 & Chuẩn Hóa Underscan (`--print-grid-mapping`)**:
  - Xác định và chứng minh nguyên nhân toán học của hiện tượng lệch tap (trên lệch lên, dưới lệch xuống, giữa khớp, toàn bộ lệch trái) do profile gốc đo ở 0° có underscan (span 1334pt vs 1280pt hiển thị).
  - Cung cấp ma trận chuẩn hóa tỷ lệ hiển thị thực tế không underscan và công cụ CLI chẩn đoán lưới 3×3 với 9 điểm độc lập.
  - Tự động sinh và nạp profile xoay 270° chuẩn hóa `TouchBridgeCalibration-rot270.json` (sai số $< 1.0$ pt trên toàn bộ 9 điểm).
  - Lưu trữ bản sao lưu an toàn `TouchBridgeCalibration.0deg.backup.json`.
- **Bộ Kiểm Thử Kiến Trúc Tự Động (91 bài kiểm thử)**: Chạy headless thông qua tham số `--test-architecture` (91/91 passed, 0 failed).
- **Tích Hợp CI GitHub Actions**: Tự động kiểm tra biên dịch và chạy bộ test kiến trúc trên macOS runner.

### Thay Đổi (Changed)
- Đồng nhất tên sản phẩm hiển thị thành `TouchBridge`.
- Giữ nguyên Bundle Identifier `com.antigravity.touchbridge.dev` và chứng chỉ ký số của nhà phát triển để bảo toàn quyền Accessibility TCC và dữ liệu hiệu chuẩn của người dùng.
- Tinh giản cây thư mục dự án: dọn dẹp các ghi chép nghiên cứu và bằng chứng thực nghiệm vào `docs/research/`.
- Chuẩn hóa quy trình build và đóng gói release zip tại `scripts/build_dev_app.sh`.

---

## [0.9.0] - 2026-09-27
### Thêm Mới (Added)
- Bộ nhận diện cử chỉ đa điểm: Tap, Double-tap, Long-press chuột phải, Cuộn 1 ngón có quán tính, Cuộn 2 ngón, Thu phóng (Pinch-to-zoom) và Xoay.
- Thuật toán thích ứng ma trận xoay màn hình tự động cho góc 90°/270°.
- Hệ thống bắt và giải phóng độc quyền phần cứng `IOHIDManager`.
- Cơ chế hiệu chuẩn 4 điểm góc kèm 2 điểm kiểm chứng độc lập.
