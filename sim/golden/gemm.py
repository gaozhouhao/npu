def gemm(a, b):
    m = len(a)
    k = len(a[0])
    n = len(b[0])

    assert len(b) == k

    c = [[0 for _ in range(n)] for _ in range(m)]

    for i in range(m):
        for j in range(n):
            acc = 0
            for kk in range(k):
                acc += a[i][kk] * b[kk][j]
            c[i][j] = acc

    return c


if __name__ == "__main__":
    A = [
        [1, 2, 3],
        [4, 5, 6],
    ]

    B = [
        [7,  8],
        [9,  10],
        [11, 12],
    ]

    C = gemm(A, B)

    for row in C:
        print(row)