# Hướng Dẫn Đóng Góp (Contributing Guidelines)

Cảm ơn bạn đã quan tâm và đóng góp cho dự án **TouchBridge**!

---

## 🧭 Nguyên Tắc Cốt Lõi

1. **An Toàn Phần Cứng & Trải Nghiệm Vật Lý**:
   - Mọi thay đổi logic cử chỉ hoặc điều khiển sự kiện chuột/cuộn phải được kiểm tra thực tế trên màn hình cảm ứng ngoài.
   - Luôn đảm bảo không bao giờ để xảy ra tình trạng kẹt chuột trái (stuck mouse-down) khi ngắt kết nối màn hình, ngủ máy (sleep) hoặc chuyển ứng dụng.
2. **Hiệu Năng & Tiết Kiệm Pin**:
   - Tránh sử dụng polling loop hoặc timer chạy liên tục khi không có ngón tay chạm trên màn hình.
   - Thao tác kéo cửa sổ và tiêu đề phải dùng đường truyền nhanh (fast-path) thay vì gọi Accessibility API chậm chạp.
3. **Bảo Toàn Quyền Trợ Năng (TCC)**:
   - Giữ nguyên Bundle Identifier `com.antigravity.touchbridge.dev` khi phát triển cục bộ để không làm mất quyền Accessibility đã được cấp bởi người dùng trong System Settings.

---

## 🛠️ Quy Trình Đóng Góp

1. **Fork & Tạo Nhánh (Branching)**:
   ```bash
   git checkout -b feature/ten-tinh-nang
   # hoặc
   git checkout -b fix/loi-cu-the
   ```

2. **Chạy Bộ Kiểm Thử Kiến Trúc**:
   Trước khi commit, hãy đảm bảo toàn bộ 86 bài test kiến trúc đều vượt qua thành công:
   ```bash
   swift run TouchBridgeProbe --test-architecture
   ```

3. **Quy Chuẩn Commit Message (Conventional Commits)**:
   - `feat(ui): thêm tùy chọn trong tab Cài đặt`
   - `fix(gesture): sửa hiện tượng trôi quán tính khi đổi hướng nhanh`
   - `docs: cập nhật hướng dẫn hiệu chuẩn màn hình`
   - `test: bổ sung ca kiểm thử cho ma trận xoay 270 độ`

4. **Tạo Pull Request**:
   - Mô tả rõ ràng mục đích thay đổi và vấn đề được giải quyết.
   - Đính kèm kết quả chạy kiểm thử tự động và kết quả thử nghiệm vật lý (nếu có).
