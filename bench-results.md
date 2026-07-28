# Bench FB Mess

T1 = đo lúc cửa sổ còn hiện (~LOAD-15s). T2 = đo sau khi đã ẩn (~LOAD+SOAK).
Control run không ẩn cửa sổ, nên T2 của nó là mức tăng theo thời gian thuần.
So sánh có ý nghĩa là **giữa các mode tại cùng mốc T**, không phải T1→T2 trong cùng mode.

| Mode | Footprint T1 (MB) | CPU T1 (%) | Footprint T2 (MB) | CPU T2 (%) | Net T2 (KB/5s) | Process |
| --- | --- | --- | --- | --- | --- | --- |
| `baseline (control, không ẩn)` | 625.4 | 4.8 | 992.7 | 8.5 | 0.4 | 5 |
| `baseline` | 657.3 | 4.9 | 651.9 | 5.2 | 0.1 | 5 |
| `throttle` | 662.6 | 5.1 | 908.2 | 8.5 | 0.2 | 5 |
| `suspend` | 712.2 | 4.8 | 681.3 | 5.0 | 0.4 | 5 |
| `block` | 687.7 | 5.2 | 641.1 | 4.4 | 0.3 | 5 |
| `throttle` | 665.1 | 4.4 | 602.6 | 3.6 | 0.0 | 5 |
| `baseline` | 748.2 | 4.4 | 704.7 | 5.4 | 0.5 | 5 |
| `block ⚠ INVALID: cửa sổ bị hiện lại giữa run` | 477.0 | 3.5 | 730.6 | 33.5 | 0.2 | 5 |
