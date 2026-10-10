# Editor MVP

Editor là ứng dụng desktop riêng, chạy trên Linux x86_64. Trên WSL cần WSLg để
mở cửa sổ đồ họa.

## Chạy

```sh
zig build editor
zig build editor-run
```

`editor-run` cần chạy từ thư mục project. File mặc định `editor_scene.json`
được lưu ở thư mục hiện hành.

## Thao tác

- `Create` hoặc các nút `+ Sprite`, `+ Wall`, `+ Pickup`: tạo object.
- Chọn object trong `Hierarchy` hoặc nhấp object trên `Scene View`.
- Chỉnh `Position` và `Size` trong `Inspector`.
- `Delete selected`: xóa object đang chọn.
- `Save` / `Open`: lưu/mở `editor_scene.json`.

Workspace co giãn theo kích thước cửa sổ: hai panel bên dùng chiều rộng thích
hợp với cửa sổ, vùng Scene View nhận phần còn lại, còn Assets / Output chạy
ngang toàn bộ cạnh dưới. Cửa sổ có kích thước tối thiểu 800×600 để các panel
không chồng lấn.

Scene JSON có `version` và danh sách object với ID, loại, vị trí, kích thước.
Khi mở file, editor kiểm tra version, số hữu hạn và kích thước dương trước khi
thay scene đang mở.

## Giới hạn hiện tại

- Scene View vẽ lưới và hình màu làm placeholder; chưa preview texture PNG.
- Danh sách assets hiện chỉ hiển thị đường dẫn mẫu, chưa có import/browser.
- Chưa hỗ trợ kéo object trực tiếp, camera/pan/zoom, tilemap, component editor
  tổng quát, undo/redo, hay chuyển scene thành dữ liệu runtime của game.
- Build editor hiện được cấu hình cho Linux x86_64, phù hợp với WSLg.

Đây là nền tảng editor để phát triển tiếp; chưa phải công cụ hoàn chỉnh để làm
và xuất bản game.
