# Bench FB Mess

T1 = đo lúc cửa sổ còn hiện (~LOAD-15s). T2 = đo sau khi đã ẩn (~LOAD+SOAK).
Control run không ẩn cửa sổ, nên T2 của nó là mức tăng theo thời gian thuần.
So sánh có ý nghĩa là **giữa các mode tại cùng mốc T**, không phải T1→T2 trong cùng mode.

| Mode | Footprint T1 (MB) | CPU T1 (%) | Footprint T2 (MB) | CPU T2 (%) | Net khi ẩn (KB/soak) | Process |
| --- | --- | --- | --- | --- | --- | --- |
| `facebook.com #1` | 683.1 | 20.7 | 646.3 | 5.0 | -3698748.0 | 4 |
| `messenger.com #1` | 622.4 | 5.4 | 588.7 | 5.4 | -771833.0 | 5 |
| `facebook.com #2` | 648.6 | 5.7 | 663.5 | 5.6 | -1586080.0 | 4 |
| `messenger.com #2` | 623.2 | 5.6 | 585.6 | 5.7 | -1432589.0 | 5 |
