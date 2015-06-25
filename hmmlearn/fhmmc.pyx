cimport cython
cimport numpy as np

import numpy as np
from libc.math cimport exp, log

ctypedef np.float64_t dtype_t
cdef dtype_t _NINF = -np.inf


@cython.boundscheck(False)
cdef inline dtype_t _max(dtype_t[:] values):
    # find maximum value (builtin 'max' is unrolled for speed)
    cdef dtype_t value
    cdef dtype_t vmax = _NINF
    for i in range(values.shape[0]):
        value = values[i]
        if value > vmax:
            vmax = value
    return vmax


@cython.boundscheck(False)
cdef dtype_t _logsumexp(dtype_t[:] X):
    cdef dtype_t vmax = _max(X)
    cdef dtype_t power_sum = 0

    for i in range(X.shape[0]):
        power_sum += exp(X[i] - vmax)

    return log(power_sum) + vmax


@cython.boundscheck(False)
def _forward(int n_observations, int n_chains, int n_states, state_combinations,
        np.ndarray[dtype_t, ndim=2] log_startprob,
        np.ndarray[dtype_t, ndim=3] log_transmat,
        np.ndarray[dtype_t, ndim=2] framelogprob,
        np.ndarray[dtype_t, ndim=2] out_fwdlattice):
    # Local variables
    cdef int t, chain_idx, idx, work_idx, state, k
    cdef int n_state_combinations = n_states ** n_chains
    state_combination_shape = tuple([n_states for _ in xrange(n_chains)])

    fwdlattice = out_fwdlattice.view()
    fwdlattice.shape = (n_observations,) + state_combination_shape

    # Allocate buffers
    cdef np.ndarray[dtype_t, ndim=1] init_buffer
    init_buffer = np.zeros(n_chains)
    cdef np.ndarray[dtype_t, ndim=1] work_buffer
    work_buffer = np.zeros(n_chains * n_states)

    # Initialize
    for idx in xrange(n_state_combinations):
        state_combination = state_combinations[idx]
        # State probabilities
        for chain_idx in xrange(n_chains):
            state = state_combination[chain_idx]
            init_buffer[chain_idx] = log_startprob[chain_idx][state]

        # Emission probability
        fwdlattice[0][state_combination] = _logsumexp(init_buffer) + framelogprob[0][idx]

    # Forward recursion
    for t in xrange(1, n_observations):
        for idx in xrange(n_state_combinations):
            state_combination = state_combinations[idx]
            # State probabilities
            for chain_idx in xrange(n_chains):
                state = state_combination[chain_idx]
                # Here we calculate all previous state combinations that are possible for this specific chain.
                # Since the chains evolve independently, this means that we only have to vary the state
                # of the current chain, hence the chain_index-th entry in the state_combination tuple.
                for k in xrange(n_states):
                    previous_state_combination = list(state_combination)
                    previous_state_combination[chain_idx] = k
                    previous_state_combination = tuple(previous_state_combination)

                    # previous probability for the current chain and state k * transition probability from state k
                    # to current state. Since all probabilities are logarithmic, addition is the correct operation.
                    work_idx = chain_idx * n_states + k
                    work_buffer[work_idx] = fwdlattice[t - 1][previous_state_combination] + log_transmat[chain_idx][k][state]

            # Emission probability
            fwdlattice[t][state_combination] = _logsumexp(work_buffer) + framelogprob[t][idx]


@cython.boundscheck(False)
def _backward(int n_observations, int n_chains, int n_states, state_combinations,
        np.ndarray[dtype_t, ndim=2] log_startprob,
        np.ndarray[dtype_t, ndim=3] log_transmat,
        np.ndarray[dtype_t, ndim=2] framelogprob,
        np.ndarray[dtype_t, ndim=2] out_bwdlattice):
    # Local variables
    cdef int t, chain_idx, idx, work_idx, state, k
    cdef int n_state_combinations = n_states ** n_chains
    state_combination_shape = tuple([n_states for _ in xrange(n_chains)])

    bwdlattice = out_bwdlattice.view()
    bwdlattice.shape = (n_observations,) + state_combination_shape

    framelogprob_reshaped = framelogprob.view()
    framelogprob_reshaped.shape = (n_observations,) + state_combination_shape

    # Allocate buffers
    cdef np.ndarray[dtype_t, ndim=1] work_buffer
    work_buffer = np.zeros(n_chains * n_states)

    # Initialize
    bwdlattice[n_observations - 1] = 0.0

    # Backward recursion
    for t in xrange(n_observations - 2, -1, -1):
        for idx in xrange(n_state_combinations):
            state_combination = state_combinations[idx]
            # State probabilities
            for chain_idx in xrange(n_chains):
                state = state_combination[chain_idx]
                # Here we calculate all previous state combinations that are possible for this specific chain.
                # Since the chains evolve independently, this means that we only have to vary the state
                # of the current chain, hence the chain_index-th entry in the state_combination tuple.
                for k in xrange(n_states):
                    previous_state_combination = list(state_combination)
                    previous_state_combination[chain_idx] = k
                    previous_state_combination = tuple(previous_state_combination)

                    # previous probability for the current chain and state k * transition probability from state k
                    # to current state. Since all probabilities are logarithmic, addition is the correct operation.
                    work_idx = chain_idx * n_states + k
                    work_buffer[work_idx] = bwdlattice[t + 1][previous_state_combination] + log_transmat[chain_idx][state][k] + framelogprob[t + 1][previous_state_combination]

            # Emission probability
            bwdlattice[t][state_combination] = _logsumexp(work_buffer)
