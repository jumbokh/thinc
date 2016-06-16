# cython: profile=True
# cython: cdivision=True
# cython: infer_types=True
cimport cython
from libc.stdlib cimport rand
from libc.string cimport memset
cimport numpy as np
import numpy

from ..typedefs cimport len_t
from ..typedefs cimport idx_t

from ..linalg cimport MatMat, MatVec, VecVec, Vec, sqrt, exp


np.import_array()


cdef weight_t EPS = 1e-5
DEF ALPHA = 1.0


cdef void ELU_forward(weight_t** fwd,
        const weight_t* W, const len_t* widths, int nr_layer, int nr_batch,
        const ConstantsC* hp) nogil:
    for i in range(1, nr_layer):
        in_ = fwd[i-1]
        out = fwd[i]
        nr_in = widths[i-1]
        nr_out = widths[i]

        MatVec.batch_dot(out,
            W, in_, nr_out, nr_in, nr_batch)
        MatVec.add_i(out,
            W + nr_out * nr_in, 1.0, nr_batch, nr_out)
        if (i+1) < nr_layer:
            ELU(out,
                nr_out * nr_batch)
        W += nr_out * nr_in + nr_out + nr_out
 
    scores = fwd[nr_layer - 1]
    nr_out = widths[nr_layer - 1]
    for _ in range(nr_batch):
        softmax(scores,
            nr_out)
        scores += nr_out


cdef void ReLu_forward(weight_t** fwd,
        const weight_t* W, const len_t* shape, int nr_below, int nr_above,
        int nr_batch, const ConstantsC* hp) nogil:
    bias = W + shape[1] * shape[0]
    dot_plus(fwd[1],
        bias, shape[1], fwd[0], shape[0], W)
    # Apply non-linearity
    if nr_above >= 2:
        ReLu(fwd[1],
            shape[1])
    else:
        softmax(fwd[1],
            shape[1])
 

cdef void dot_plus(weight_t* out,
        const weight_t* bias, len_t nr_out,
        const weight_t* x, len_t nr_in,
        const weight_t* W) nogil:
    MatVec.dot(out,
        W, x, nr_out, nr_in)
    cdef weight_t one = 1.0
    if bias is not NULL:
        VecVec.add_i(out,
            bias, one, nr_out)


cdef void ELU(weight_t* out, len_t nr_out) nogil:
    cdef idx_t i
    for i in range(nr_out):
        if out[i] < 0:
            out[i] = ALPHA * (exp(out[i]) - 1)


cdef void ReLu(weight_t* out, len_t nr_out) nogil:
    cdef idx_t i
    for i in range(nr_out):
        if out[i] < 0:
            out[i] = 0


cdef void softmax(weight_t* out, len_t nr_out) nogil:
    #w = exp(w - max(w))
    Vec.add_i(out,
        -Vec.max(out, nr_out), nr_out)
    Vec.exp_i(out,
        nr_out)
    #w = w / sum(w)
    cdef weight_t norm = Vec.sum(out, nr_out)
    if norm != 0:
        Vec.div_i(out,
            norm, nr_out)


cdef void ELU_batch_norm_forward(weight_t** fwd,
        const weight_t* W, const len_t* widths, int nr_layer, int nr_batch,
        const ConstantsC* hp) nogil:
    
    for i in range(nr_layer-2):
        MatVec.batch_dot(fwd[i+1],
            W, fwd[i], widths[i+1], widths[i], nr_batch)
        with gil:
            normalize(fwd[i+1],
                nr_batch, widths[i+1])
        # Affine transformation with bias and gamma
        #MatVec.mul_i(fwd[i+1],
        #    W + widths[i+1] * widths[i] + widths[i+1], widths[i+1], nr_batch)
        MatVec.add_i(fwd[i+1],
            W + widths[i+1] * widths[i], 1.0, nr_batch, widths[i+1])
 
        # Activate
        ReLu(fwd[i+1],
            widths[i+1] * nr_batch)
        W += widths[i+1] * widths[i] + widths[i+1] + widths[i+1]
 
    i = nr_layer - 2
    MatVec.batch_dot(fwd[i+1],
        W, fwd[i], widths[i+1], widths[i], nr_batch)
    MatVec.add_i(fwd[i+1],
        W + widths[i+1] * widths[i], 1.0, nr_batch, widths[i+1])
 
    scores = fwd[i+1]
    for _ in range(nr_batch):
        softmax(scores,
            widths[i+1])
        scores += widths[i+1]


cdef void normalize(weight_t* x, int nr_batch, int n) except *:
    cdef weight_t[300] Ex
    for i in range(n):
        Ex[i] = 0
    for i in range(nr_batch):
        VecVec.add_i(Ex, x + (i * n), 1.0, n)
    Vec.mul_i(Ex, 1.0 / nr_batch, n)
    cdef weight_t[300] Vx
    for i in range(300):
        Vx[i] = 0
    for i in range(nr_batch):
        VecVec.add_i(x + (i * n), Ex, -1.0, n)
        VecVec.add_pow_i(Vx, x + (i * n), 2.0, n)
    Vec.mul_i(Vx, 1.0 / nr_batch, n)
    for i in range(nr_batch):
        for j in range(n):
            x[i * n + j] /= sqrt(Vx[j] + EPS)
