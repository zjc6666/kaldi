// nnet3/nnet-training.cc

// Copyright      2015    Johns Hopkins University (author: Daniel Povey)

// See ../../COPYING for clarification regarding multiple authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
// WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
// MERCHANTABLITY OR NON-INFRINGEMENT.
// See the Apache 2 License for the specific language governing permissions and
// limitations under the License.

#include "nnet3/nnet-training.h"
#include "nnet3/nnet-utils.h"

namespace kaldi {
namespace nnet3 {

NnetTrainer::NnetTrainer(const NnetTrainerOptions &config,
                         Nnet *nnet):
    config_(config),
    nnet_(nnet),
    compiler_(*nnet, config_.optimize_config),
    num_minibatches_processed_(0) {
  if (config.zero_component_stats)
    ZeroComponentStats(nnet);
  if (config.momentum == 0.0 && config.max_param_change == 0.0) {
    delta_nnet_= NULL;
  } else {
    KALDI_ASSERT(config.momentum >= 0.0 &&
                 config.max_param_change >= 0.0);
    delta_nnet_ = nnet_->Copy();
    bool is_gradient = false;  // setting this to true would disable the
                               // natural-gradient updates.
    SetZero(is_gradient, delta_nnet_);
  }
  if (!config.objective_scales_str.empty()) {

    std::vector<std::string> objective_scales;
    SplitStringToVector(config.objective_scales_str, ":", 
                        false, &objective_scales);
    if (objective_scales.size() %2 != 0) {
      KALDI_ERR << "Incorrect format for objective-scales-str " 
                << config.objective_scales_str;
    }
    
    for (int32 i = 0; i < objective_scales.size(); i += 2) {
      std::string &output_name = objective_scales[i];
      BaseFloat scale;

      if (!ConvertStringToReal(objective_scales[i+1], &scale)) {
        KALDI_ERR << "Could not convert objective-scale " 
                  << objective_scales[i+1] << " to float.";
      }

      objective_scales_[output_name] = scale;
    }
  }
}

void NnetTrainer::Train(const NnetExample &eg) {
  bool need_model_derivative = true;
  ComputationRequest request;
  GetComputationRequest(*nnet_, eg, need_model_derivative,
                        config_.store_component_stats, 
                        config_.add_regularizer,
                        &request);
  const NnetComputation *computation = compiler_.Compile(request);

  NnetComputer computer(config_.compute_config, *computation,
                        *nnet_,
                        (delta_nnet_ == NULL ? nnet_ : delta_nnet_));
  // give the inputs to the computer object.
  computer.AcceptInputs(*nnet_, eg.io);
  computer.Forward();

  this->ProcessOutputs(eg, &computer);
  computer.Backward();

  if (delta_nnet_ != NULL) {
    BaseFloat scale = (1.0 - config_.momentum);
    if (config_.max_param_change != 0.0) {
      BaseFloat param_delta =
          std::sqrt(DotProduct(*delta_nnet_, *delta_nnet_)) * scale;
      if (param_delta > config_.max_param_change) {
        if (param_delta - param_delta != 0.0) {
          KALDI_WARN << "Infinite parameter change, will not apply.";
          SetZero(false, delta_nnet_);
        } else {
          scale *= config_.max_param_change / param_delta;
          KALDI_LOG << "Parameter change too big: " << param_delta << " > "
                    << "--max-param-change=" << config_.max_param_change
                    << ", scaling by " << config_.max_param_change / param_delta;
        }
      }
    }
    AddNnet(*delta_nnet_, scale, nnet_);
    ScaleNnet(config_.momentum, delta_nnet_);
  }
}

void NnetTrainer::ProcessOutputs(const NnetExample &eg,
                                 NnetComputer *computer) {
  std::vector<NnetIo>::const_iterator iter = eg.io.begin(),
      end = eg.io.end();
  for (; iter != end; ++iter) {
    const NnetIo &io = *iter;
    int32 node_index = nnet_->GetNodeIndex(io.name);
    KALDI_ASSERT(node_index >= 0);
    if (nnet_->IsOutputNode(node_index)) {
      ObjectiveType obj_type = nnet_->GetNode(node_index).u.objective_type;
      BaseFloat scale = 1.0; 
      if (objective_scales_.count(io.name) > 0)
        scale = objective_scales_[io.name];
      
      BaseFloat tot_weight, tot_objf;
      bool supply_deriv = true;

      const CuMatrixBase<BaseFloat> &nnet_output = computer->GetOutput(io.name);
      CuMatrix<BaseFloat> nnet_output_deriv(nnet_output.NumRows(),
                                            nnet_output.NumCols(),
                                            kUndefined);

      ComputeObjectiveFunction(io.features, obj_type, io.name, nnet_output,
                               &tot_weight, &tot_objf,
                               supply_deriv ? &nnet_output_deriv : NULL);

      tot_objf *= scale;

      if (supply_deriv) {
        if (config_.apply_deriv_weights && io.deriv_weights.Dim() != 0) {
          CuVector<BaseFloat> cu_deriv_weights(io.deriv_weights);
          nnet_output_deriv.MulRowsVec(cu_deriv_weights);
        }

        if (scale != 1.0) 
          nnet_output_deriv.Scale(scale);

        computer->AcceptOutputDeriv(io.name, &nnet_output_deriv);
      }

      objf_info_[io.name].UpdateStats(io.name, config_.print_interval,
                                      num_minibatches_processed_++,
                                      tot_weight, tot_objf);
      
      if (config_.add_regularizer) {
        std::string reg_name = io.name + "-reg";
        int32 reg_node_index = nnet_->GetNodeIndex(reg_name);

        if (reg_node_index >= 0) {
          KALDI_ASSERT(nnet_->IsOutputNode(reg_node_index));

          BaseFloat regularizer_scale = 1.0;

          if (objective_scales_.count(reg_name) > 0)
            regularizer_scale = objective_scales_[reg_name];

          BaseFloat tot_reg_weight, tot_reg_objf;
          bool supply_deriv = true;

          const CuMatrixBase<BaseFloat> &reg_output = computer->GetOutput(reg_name);
          CuMatrix<BaseFloat> reg_output_deriv(reg_output.NumRows(),
              reg_output.NumCols(),
              kUndefined);

          ComputeRegularizer(obj_type, reg_name, reg_output,
              &tot_reg_weight, &tot_reg_objf,
              supply_deriv ? &reg_output_deriv : NULL);

          tot_reg_objf *= scale;

          if (supply_deriv) {
            if (config_.apply_deriv_weights && io.deriv_weights.Dim() != 0) {
              CuVector<BaseFloat> cu_deriv_weights(io.deriv_weights);
              reg_output_deriv.MulRowsVec(cu_deriv_weights);
            }

            if (regularizer_scale != 1.0) 
              reg_output_deriv.Scale(regularizer_scale);

            computer->AcceptOutputDeriv(reg_name, &reg_output_deriv);
          }

          objf_info_[reg_name].UpdateStats(reg_name, config_.print_interval,
              num_minibatches_processed_++,
              tot_reg_weight, tot_reg_objf);
        }
      }
    }
  }
}

bool NnetTrainer::PrintTotalStats() const {
  unordered_map<std::string, ObjectiveFunctionInfo>::const_iterator
      iter = objf_info_.begin(),
      end = objf_info_.end();
  bool ans = false;
  for (; iter != end; ++iter) {
    const std::string &name = iter->first;
    const ObjectiveFunctionInfo &info = iter->second;
    ans = ans || info.PrintTotalStats(name);
  }
  return ans;
}

void ObjectiveFunctionInfo::UpdateStats(
    const std::string &output_name,
    int32 minibatches_per_phase,
    int32 minibatch_counter,
    BaseFloat this_minibatch_weight,
    BaseFloat this_minibatch_tot_objf,
    BaseFloat this_minibatch_tot_aux_objf) {
  int32 phase = minibatch_counter / minibatches_per_phase;
  if (phase != current_phase) {
    KALDI_ASSERT(phase == current_phase + 1); // or doesn't really make sense.
    PrintStatsForThisPhase(output_name, minibatches_per_phase);
    current_phase = phase;
    tot_weight_this_phase = 0.0;
    tot_objf_this_phase = 0.0;
    tot_aux_objf_this_phase = 0.0;
  }
  tot_weight_this_phase += this_minibatch_weight;
  tot_objf_this_phase += this_minibatch_tot_objf;
  tot_aux_objf_this_phase += this_minibatch_tot_aux_objf;
  tot_weight += this_minibatch_weight;
  tot_objf += this_minibatch_tot_objf;
  tot_aux_objf += this_minibatch_tot_aux_objf;
}

void ObjectiveFunctionInfo::PrintStatsForThisPhase(
    const std::string &output_name,
    int32 minibatches_per_phase) const {
  int32 start_minibatch = current_phase * minibatches_per_phase,
      end_minibatch = start_minibatch + minibatches_per_phase - 1;

  if (tot_aux_objf_this_phase == 0.0) {
    KALDI_LOG << "Average objective function for '" << output_name
              << "' for minibatches " << start_minibatch
              << '-' << end_minibatch << " is "
              << (tot_objf_this_phase / tot_weight_this_phase) << " over "
              << tot_weight_this_phase << " frames.";
  } else {
    BaseFloat objf = (tot_objf_this_phase / tot_weight_this_phase),
        aux_objf = (tot_aux_objf_this_phase / tot_weight_this_phase),
        sum_objf = objf + aux_objf;
    KALDI_LOG << "Average objective function for '" << output_name
              << "' for minibatches " << start_minibatch
              << '-' << end_minibatch << " is "
              << objf << " + " << aux_objf << " = " << sum_objf
              << " over " << tot_weight_this_phase << " frames.";
  }
}

bool ObjectiveFunctionInfo::PrintTotalStats(const std::string &name) const {
  BaseFloat objf = (tot_objf / tot_weight),
        aux_objf = (tot_aux_objf / tot_weight),
        sum_objf = objf + aux_objf;
  if (tot_aux_objf == 0.0) {
    KALDI_LOG << "Overall average objective function for '" << name << "' is "
              << (tot_objf / tot_weight) << " over " << tot_weight << " frames.";
  } else {
    KALDI_LOG << "Overall average objective function for '" << name << "' is "
              << objf << " + " << aux_objf << " = " << sum_objf        
              << " over " << tot_weight << " frames.";
  }
  KALDI_LOG << "[this line is to be parsed by a script:] "
            << "log-prob-per-frame="
            << objf;
  return (tot_weight != 0.0);
}

NnetTrainer::~NnetTrainer() {
  delete delta_nnet_;
}

void ComputeObjectiveFunction(const GeneralMatrix &supervision,
                              ObjectiveType objective_type,
                              const std::string &output_name,
                              const CuMatrixBase<BaseFloat> &output,
                              BaseFloat *tot_weight,
                              BaseFloat *tot_objf,
                              CuMatrixBase<BaseFloat> *output_deriv) {
  if (output.NumCols() != supervision.NumCols())
    KALDI_ERR << "Nnet versus example output dimension (num-classes) "
              << "mismatch for '" << output_name << "': " << output.NumCols()
              << " (nnet) vs. " << supervision.NumCols() << " (egs)\n";

  switch (objective_type) {
    case kCrossEntropy: {
      // objective is x * log(y) + (1-x) * log(1-y)
      CuMatrix<BaseFloat> cu_post(supervision.NumRows(), supervision.NumCols(),
                                  kUndefined);  // x
      cu_post.CopyFromGeneralMat(supervision);

      CuMatrix<BaseFloat> n_cu_post(cu_post.NumRows(), cu_post.NumCols());
      n_cu_post.Set(1.0);
      n_cu_post.AddMat(-1.0, cu_post);          // 1-x

      CuMatrix<BaseFloat> log_prob(output);     // y
      log_prob.ApplyLog();                      // log(y)

      CuMatrix<BaseFloat> n_output(output.NumRows(), output.NumCols(), kSetZero);
      n_output.Set(1.0);  
      n_output.AddMat(-1.0, output);            // 1-y
      n_output.ApplyLog();                      // log(1-y)

      *tot_weight = cu_post.NumRows() * cu_post.NumCols();
      *tot_objf = TraceMatMat(log_prob, cu_post, kTrans) 
                  + TraceMatMat(n_output, n_cu_post, kTrans);

      if (output_deriv) {
        // deriv is x / y - (1-x) / (1-y)
        n_output.ApplyExp();                    // 1-y
        n_cu_post.DivElements(n_output);        // 1-x / (1-y)

        log_prob.ApplyExp();                    // y
        cu_post.DivElements(log_prob);          // x / y
 
        output_deriv->CopyFromMat(cu_post);     // x / y
        output_deriv->AddMat(-1.0, n_cu_post);       // x / y - (1-x) / (1-y)
      }
                                   
      break;
    }
    case kLinear: {
      // objective is x * y.
      switch (supervision.Type()) {
        case kSparseMatrix: {
          const SparseMatrix<BaseFloat> &post = supervision.GetSparseMatrix();
          CuSparseMatrix<BaseFloat> cu_post(post);
          // The cross-entropy objective is computed by a simple dot product,
          // because after the LogSoftmaxLayer, the output is already in the form
          // of log-likelihoods that are normalized to sum to one.
          *tot_weight = cu_post.Sum();
          *tot_objf = TraceMatSmat(output, cu_post, kTrans);
          if (output_deriv) {
            cu_post.CopyToMat(output_deriv);
          }
          break;
        }
        case kFullMatrix: {
          // there is a redundant matrix copy in here if we're not using a GPU
          // but we don't anticipate this code branch being used in many cases.
          if (output_deriv) {
            supervision.CopyToMat(output_deriv);
            CuMatrixBase<BaseFloat> &cu_post = *output_deriv;
            *tot_weight = cu_post.Sum();
            *tot_objf = TraceMatMat(output, cu_post, kTrans);
          } else {
            CuMatrix<BaseFloat> cu_post(supervision.GetFullMatrix());
            *tot_weight = cu_post.Sum();
            *tot_objf = TraceMatMat(output, cu_post, kTrans);
          }
          break;
        }
        case kCompressedMatrix: {
          Matrix<BaseFloat> post;
          supervision.GetMatrix(&post);
          if (output_deriv) {
            output_deriv->CopyFromMat(post);
            CuMatrixBase<BaseFloat> &cu_post = *output_deriv;
            *tot_weight = cu_post.Sum();
            *tot_objf = TraceMatMat(output, cu_post, kTrans);
          } else {
            CuMatrix<BaseFloat> cu_post;
            cu_post.Swap(&post);
            *tot_weight = cu_post.Sum();
            *tot_objf = TraceMatMat(output, cu_post, kTrans);
          }
          break;
        }
      }
      break;
    }
    case kQuadratic: {
      // objective is -0.5 (x - y)^2
      if (output_deriv) {
        CuMatrixBase<BaseFloat> &diff = *output_deriv;
        diff.CopyFromGeneralMat(supervision);
        diff.AddMat(-1.0, output);
        *tot_weight = diff.NumRows();
        *tot_objf = -0.5 * TraceMatMat(diff, diff, kTrans);
      } else {
        CuMatrix<BaseFloat> diff(supervision.NumRows(),
                                 supervision.NumCols(),
                                 kUndefined);
        diff.CopyFromGeneralMat(supervision);
        diff.AddMat(-1.0, output);
        *tot_weight = diff.NumRows();
        *tot_objf = -0.5 * TraceMatMat(diff, diff, kTrans);
      }
      break;
    }
    default:
      KALDI_ERR << "Objective function type " << objective_type
                << " not handled.";
  }
}

void ComputeRegularizer(ObjectiveType objective_type,
                        const std::string &output_name,
                        const CuMatrixBase<BaseFloat> &output,
                        BaseFloat *tot_weight,
                        BaseFloat *tot_objf,
                        CuMatrixBase<BaseFloat> *output_deriv) {
  KALDI_VLOG(1) << output;
  switch (objective_type) {
    case kLinear: {
      // objective is x
      *tot_weight = output.NumRows();
      *tot_objf = output.Sum();
      if (output_deriv) {
        output_deriv->Set(1.0);
      }
      break;
    } 
    case kQuadratic: {
      // objective is -0.5 x^2
      *tot_weight = output.NumRows();
      *tot_objf = -0.5 * TraceMatMat(output, output, kTrans);
      if (output_deriv) {
        output_deriv->CopyFromMat(output);
        output_deriv->Scale(1.0);
      } 
      break;
    }
    default:
      KALDI_ERR << "Regularizer objective function type " << objective_type
                << " not handled.";
  }
}

} // namespace nnet3
} // namespace kaldi
