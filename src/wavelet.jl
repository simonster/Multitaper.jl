# FrequencyDomainAnalysis.jl
# Tools for spectral density estimation and analysis of phase relationships
# between sets of signals.

# Copyright (C) 2013   Simon Kornblith

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

import Base: getindex, size, ndims, convert
export MorletWavelet, wavebases, wavecoi, ContinuousWaveletTransform, cwt

#
# Mother wavelets, which are convolved with the signal in frequency space
#
abstract MotherWavelet{T}

immutable MorletWavelet{T} <: MotherWavelet{T}
    k0::T
    foi::Vector{T}
    fourierfactor::T
end
MorletWavelet{T<:Real}(foi::Vector{T}, k0::Real=5.0) =
    MorletWavelet(convert(T, k0), foi, convert(T, (4pi)/(k0 + sqrt(2 + k0^2))))

function wavebases{T}(w::MorletWavelet{T}, n::Int, fs::Real=1)
    df = 2pi * fs / n
    normconst = df / sqrt(pi) * n
    k0 = w.k0

    bases = Array(T, div(n, 2)+1, length(w.foi))
    for k = 1:length(w.foi)
        scale = 1/(w.foi[k] * w.fourierfactor)
        bases[1, k] = zero(T)
        norm = sqrt(scale * normconst)
        for j = 2:size(bases, 1)
            bases[j, k] = norm * exp(-abs2(scale * df * (j-1) - k0)*0.5)
        end
    end
    bases
end

function wavecoi{T}(w::MorletWavelet{T}, fs::Real=1)
    [sqrt(2) * fs / (f * w.fourierfactor) for f in w.foi]
end

immutable ContinuousWaveletTransform{T,S}
    fftin::Vector{T}
    fftout::Vector{S}
    ifftwork::Vector{S}
    bases::Array{T,2}
    coi::Vector{T}
    p1::FFTW.Plan{T}
    p2::FFTW.Plan{S}
end

function ContinuousWaveletTransform{T}(w::MotherWavelet{T}, nfft::Int, fs::Real=1)
    fftin = Array(T, nfft)
    fftout = zeros(Complex{T}, div(nfft, 2)+1)
    ifftwork = zeros(Complex{T}, nfft)
    bases = wavebases(w, nfft, fs)
    coi = wavecoi(w, fs)
    p1 = FFTW.Plan(fftin, fftout, 1, FFTW.ESTIMATE, FFTW.NO_TIMELIMIT)
    p2 = FFTW.Plan(ifftwork, ifftwork, 1, FFTW.BACKWARD, FFTW.ESTIMATE, FFTW.NO_TIMELIMIT)
    ContinuousWaveletTransform(fftin, fftout, ifftwork, bases, coi, p1, p2)
end

function evaluate!{T}(out::Array{Complex{T}, 2}, t::ContinuousWaveletTransform{T}, signal::Vector{T})
    @inbounds begin
        fftin = t.fftin
        fftout = t.fftout
        ifftwork = t.ifftwork
        bases = t.bases

        nsignal = length(signal)
        nfft = length(fftin)
        nrfft = length(fftout)

        nsignal <= nfft || error("signal exceeds length of transform plan")
        size(out, 1) == length(signal) || error("first dimension of out must match length of signal")
        size(out, 2) == size(bases, 2) || error("second dimension of out must match number of wavelets")

        # Get indices of discarded samples
        discard_samples = isnan(signal)
        discard_samples[1] = false
        discard_samples[end] = false
        discard_sample_indices = find(discard_samples)

        # Copy original data, set discarded samples to zero
        copy!(fftin, signal)
        fftin[discard_sample_indices] = 0
        for j = length(signal)+1:nfft
            fftin[j] = 0
        end

        # Perform FFT of padded signal
        FFTW.execute(T, t.p1.plan)

        for k = 1:size(bases, 2)
            # Multiply by wavelet
            for j = 1:nrfft
                ifftwork[j] = fftout[j] * bases[j, k]
            end

            # We only compute the real FFT, but we may need the imaginary
            # frequencies for some mother wavelets as well
            offset = nrfft + 1 + isodd(nfft)
            for j = nrfft+1:size(bases, 1)
                ifftwork[j] = conj(fftout[offset-j]) * bases[j, k]
            end

            # Zero remaining frequencies
            for j = size(bases, 1)+1:nfft
                ifftwork[j] = 0
            end

            # Perform FFT
            FFTW.execute(T, t.p2.plan)

            # Copy to output array and divide by normalization factor
            for i = 1:nsignal
                out[i, k] = ifftwork[i]/nfft
            end

            # Set NaNs at edges
            coi_length = iceil(t.coi[k])
            out[1:min(coi_length, nsignal), k] = NaN
            out[max(nsignal-coi_length+1, 1):end, k] = NaN

            # Set NaNs for gaps
            for i in discard_sample_indices
                out[i, k] = NaN
                if !discard_samples[i+1]
                    out[i:min(i+coi_length, nsignal), k] = NaN
                end
                if !discard_samples[i-1]
                    out[max(i-coi_length, 1):i, k] = NaN
                end
            end
        end
    end
    out
end

# Friendly interface to ContinuousWaveletTransform
function cwt{T <: Real}(signal::Vector{T}, w::MotherWavelet, fs::Real=1)
    t = ContinuousWaveletTransform(w, nextprod([2, 3, 5, 7], length(signal)), fs)
    evaluate!(Array(Complex{T}, length(signal), size(t.bases, 2)), t, signal)
end