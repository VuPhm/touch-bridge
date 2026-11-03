## Mô tả thay đổi (Summary of Changes)
<!-- Tóm tắt ngắn gọn mục tiêu của Pull Request này -->

## Loại thay đổi (Type of Change)
- [ ] Sửa lỗi (Bug fix)
- [ ] Tính năng mới (New feature)
- [ ] Tối ưu hóa / Refactor (Performance & Code quality)
- [ ] Cập nhật tài liệu (Documentation)
- [ ] CI / Build tooling

## Kiểm chứng & Thử nghiệm (Verification & Testing)
- [ ] Chạy bộ kiểm thử kiến trúc thành công: `swift run TouchBridgeProbe --test-architecture` (85/85 tests passed)
- [ ] Đã thử nghiệm vật lý trên màn hình cảm ứng ngoài:
  - [ ] Chạm (Tap) & Nhấp đúp (Double tap)
  - [ ] Cuộn 1 ngón & Quán tính ngắn
  - [ ] Nhấn giữ chuột phải
  - [ ] Kéo thanh tiêu đề cửa sổ (Fast path drag)
  - [ ] Cử chỉ 2 ngón (Pinch / Zoom / Rotate)
  - [ ] Rút cáp / Cắm lại / Sleep / Wake không bị kẹt chuột

## Checklist
- [ ] Giữ nguyên Bundle Identifier `com.antigravity.touchbridge.dev` để bảo toàn quyền TCC.
- [ ] Mã nguồn được định dạng sạch và không phát sinh warning mới.
- [ ] Đã cập nhật CHANGELOG.md và README.md nếu có thay đổi hành vi người dùng.
